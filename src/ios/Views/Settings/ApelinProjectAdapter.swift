import Foundation

// ApelinProject's pure model files are vendored unchanged; see ApelinTemplates/PROVENANCE.json.
// This bounded, no-symlink reader is the only ProjectFiles operation used by TemplateDigest.
extension TemplateError: LocalizedError {
    public var errorDescription: String? { description }
}

enum ProjectFiles {
    static func checkedURL(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\0"), !path.contains("\\") else {
            throw TemplateError("Unsafe relative path: \(path)")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = canonicalRoot.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw TemplateError("Symbolic link: \(path)")
        }
        return url
    }
    static func read(_ path: String, in root: URL) throws -> Data {
        let url = try checkedURL(path, in: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262144 else {
            throw TemplateError("Not a regular file or exceeds 256 KB: \(path)")
        }
        return try Data(contentsOf: url)
    }
}

enum MinisProjectTemplate: String, CaseIterable, Identifiable {
    case linux = "c-cli", app = "apelin-app", cli = "apelin-cli"
    case tweak = "apelin-tweak", preferences = "apelin-preferences"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .linux: return "C CLI · Linux"
        case .app: return "ObjC App · iOS"
        case .cli: return "ObjC CLI · iOS"
        case .tweak: return "ObjC Tweak · iOS"
        case .preferences: return "ObjC Preferences · iOS"
        }
    }
    var kind: String { String(rawValue.dropFirst(7)) }
    var templateID: String {
        switch self {
        case .app: return "uikit-objc"
        case .cli: return "objc"
        case .tweak: return "objc-hook"
        case .preferences: return "objc-bundle"
        case .linux: return "c"
        }
    }
}

enum ApelinProjectAdapter {
    static let unboundDigest = "sha256:" + String(repeating: "0", count: 64)
    static var resources: URL {
        get throws {
            guard let url = Bundle.main.url(forResource: "ApelinTemplates", withExtension: nil) else {
                throw TemplateError("缺少 ApelinTemplates 应用资源。")
            }
            return url
        }
    }
    static func descriptor(_ choice: MinisProjectTemplate) throws -> (URL, ExtensionManifest, ExtensionManifest.Template) {
        guard choice != .linux else { throw TemplateError("Linux template has its own store.") }
        let root = try resources.appendingPathComponent("wiki.qaq.apelin.dev." + choice.kind)
        let document = try StrictJSON.parse(ProjectFiles.read("manifest.json", in: root))
        let errors = ManifestValidation.errors(document)
        guard errors.isEmpty else { throw TemplateError(errors.joined(separator: "\n")) }
        let manifest = try ExtensionManifest(document: document)
        guard let template = manifest.templates.first(where: { $0.id == choice.templateID }) else {
            throw TemplateError("模板不存在。")
        }
        return (root, manifest, template)
    }
    static func previewFiles(_ choice: MinisProjectTemplate) throws -> [String] {
        let (_, _, template) = try descriptor(choice)
        return ["minis-project.json"] + template.files.filter { $0.format != "copy" }.map(\.path)
            + ["README.md", "APELIN-LICENSE.txt", "APELIN-EXTENSION.json", "APELIN-PROVENANCE.json"]
    }
    static func validate(_ data: Data, choice: MinisProjectTemplate, id: UUID) throws {
        let (_, project) = try ProjectValidation.load(data)
        let (_, manifest, template) = try descriptor(choice)
        guard project.projectID == id.uuidString.lowercased(), project.kind.rawValue == choice.kind,
              project.template.extensionID == manifest.id, project.template.templateID == template.id,
              project.template.version == manifest.version, project.template.digest == template.digest else {
            throw TemplateError("Apelin 清单身份或模板来源与项目记录不一致。")
        }
    }
    static func generate(_ choice: MinisProjectTemplate, name: String, id: UUID, into destination: URL) throws {
        let (extensionRoot, manifest, template) = try descriptor(choice)
        guard name.range(of: "\\A[a-zA-Z][a-zA-Z0-9_-]{0,47}\\z", options: .regularExpression) != nil else {
            throw TemplateError("Invalid project name.")
        }
        let templateRoot = try ProjectFiles.checkedURL(template.directory, in: extensionRoot)
        guard try TemplateDigest.compute(templateRoot: templateRoot, files: template.files) == template.digest else {
            throw TemplateError("上游模板摘要不匹配。")
        }
        let types = TemplateParameters.types(for: template)
        // These identifiers are explicit sentinels, not invented SDK/toolchain registrations.
        // A future backend must replace BOTH bindings with real registry IDs and digests.
        let product = name.replacingOccurrences(of: "-", with: "_")
        let identifier = "com.example." + name.lowercased().replacingOccurrences(of: "_", with: "-")
        var values: [String: JSONDocument] = [
            "projectName": .string(name), "projectID": .string(id.uuidString.lowercased()),
            "bundleID": .string(identifier), "packageID": .string(identifier),
            "deploymentTarget": .string("16.0"),
            "architectures": .object(JSONObject([("rootless", .array([.string("arm64"), .string("arm64e")])), ("roothide", .array([.string("arm64e")]))])),
            "templateExtensionID": .string(manifest.id), "templateID": .string(template.id),
            "templateVersion": .string(manifest.version), "templateDigest": .string(template.digest),
            "toolchainID": .string("minis-unbound-toolchain"), "toolchainDigest": .string(unboundDigest),
            "sdkID": .string("minis-unbound-sdk"), "sdkDigest": .string(unboundDigest)
        ]
        for parameter in template.parameters { values[parameter.name] = parameter.default?.value }
        values["productName"] = .string(product)
        values["displayName"] = .string(name)
        values["summary"] = .string("Created from an Apelin template in Minis.")
        values["author"] = .string("Minis User")
        for (key, value) in values {
            guard let type = types[key] else { throw TemplateError("Unknown parameter: \(key)") }
            try TemplateParameters.validate(key, type, value)
        }
        for file in template.files {
            let errors = TemplateParameters.checkPath(file.path, types: types, where: file.path)
            guard errors.isEmpty else { throw TemplateError(errors.joined(separator: "\n")) }
            let path = try TemplateParameters.substitutePath(file.path, values: values)
            let output = try ProjectFiles.checkedURL(path, in: destination)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw TemplateError("Refusing to overwrite template output: \(path)")
            }
            let original = try ProjectFiles.read(file.path, in: templateRoot)
            let data: Data
            if file.format == "copy" { data = original } else {
                guard let text = String(data: original, encoding: .utf8) else { throw TemplateError("Invalid UTF-8") }
                let problems = TemplateParameters.checkText(text, format: file.format, types: types, where: path)
                guard problems.isEmpty else { throw TemplateError(problems.joined(separator: "\n")) }
                data = Data(try TemplateParameters.substitute(text, format: file.format, types: types, values: values).utf8)
                if file.format == "plist-xml" { _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
            }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
            if let mode = file.mode, let numeric = Int(mode, radix: 8) {
                try FileManager.default.setAttributes([.posixPermissions: numeric], ofItemAtPath: output.path)
            }
        }
        try validate(ProjectFiles.read("apelin-project.json", in: destination), choice: choice, id: id)
        try ProjectFiles.read("LICENSE", in: extensionRoot).write(to: destination.appendingPathComponent("APELIN-LICENSE.txt"))
        try ProjectFiles.read("manifest.json", in: extensionRoot).write(to: destination.appendingPathComponent("APELIN-EXTENSION.json"))
        try ProjectFiles.read("PROVENANCE.json", in: resources).write(to: destination.appendingPathComponent("APELIN-PROVENANCE.json"))
        let readme = """
        # \(name)

        \(choice.title), Apelin schema v1; \(manifest.id) \(manifest.version) / \(template.id).
        Template digest: \(template.digest)
        Source: https://github.com/owngoal-dev/Apelin (local archive; see APELIN-PROVENANCE.json).
        MIT notices and nested provenance: APELIN-LICENSE.txt and APELIN-EXTENSION.json.

        Creation only. No build, signing, install or device capability has been verified.
        The environment bindings minis-unbound-toolchain / minis-unbound-sdk and zero digests
        are explicit UNBOUND sentinels. Replace both with actual verified Apelin registry bindings
        before building. Schema validation does not establish environment availability.
        Templates target jailbroken iOS 16+ rootless/roothide, NOT the Minis Linux guest.
        App entitlements include platform/no-sandbox privileges; ordinary signing cannot grant them.
        Tweak targets SpringBoard by default. Preferences requires PreferenceLoader and the private
        Preferences framework. Required extension support remains in the bundled original extension;
        install the matching Apelin extension in a real backend before a build. No installer is provided.
        Edit source, package/bundle identifiers, target filter and author before use.
        """ + "\n"
        try readme.write(to: destination.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }
}
