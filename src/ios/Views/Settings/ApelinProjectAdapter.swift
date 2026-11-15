import Foundation
import Darwin

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

// Shared by the app editor and the macOS Swift model harness. Never executes files.
enum DevelopmentProjectEditing {
    static let byteLimit = 262144
    struct Snapshot {
        let data: Data
        let device: dev_t
        let inode: ino_t
        let modified: timespec
        let changed: timespec
        let mode: mode_t
        var text: String { String(data: data, encoding: .utf8)! }
    }
    static func editableFiles(_ choice: MinisProjectTemplate) throws -> [String] {
        if choice == .linux { return ["Sources/main.c", "build.sh", "README.md"] }
        let (_, _, template) = try ApelinProjectAdapter.descriptor(choice)
        return template.files.filter { $0.format != "copy" }.map(\.path) + ["README.md"]
    }
    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\0"), !path.contains("\\") else { throw TemplateError("不安全的文件路径。") }
        return parts
    }
    static func check(_ file: String, choice: MinisProjectTemplate) throws {
        _ = try components(file)
        guard try editableFiles(choice).contains(file) else { throw TemplateError("此文件不支持编辑；身份与来源记录为只读。") }
    }
    // Walk every directory with O_NOFOLLOW, including the supplied app-group root.
    // Directory descriptors keep later operations anchored if a path is replaced.
    static func parent(_ root: URL, file: String) throws -> (Int32, String) {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw TemplateError("项目根路径无效。") }
        let parts = try components(file)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw TemplateError("无法打开项目根目录。") }
        do {
            for part in root.path.split(separator: "/").map(String.init) + Array(parts.dropLast()) {
                guard part != ".", part != ".." else { throw TemplateError("不安全的目录路径。") }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw TemplateError("目录不可访问或包含符号链接：\(part)（errno=\(errno)，root=\(root.path)）。") }
                close(fd); fd = next
            }
            return (fd, parts.last!)
        } catch { close(fd); throw error }
    }
    static func readAt(_ parent: Int32, _ name: String) throws -> Snapshot {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TemplateError("文件不可访问或包含符号链接。") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= off_t(byteLimit) else {
            throw TemplateError("仅支持单一链接的普通文件，最大 256 KiB。")
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw TemplateError("读取文件失败。") }
            if count == 0 { break }
            guard bytes.count + count <= byteLimit else { throw TemplateError("文件超过 256 KiB。") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, same(before, after), bytes.count == Int(after.st_size),
              String(data: bytes, encoding: .utf8) != nil else { throw TemplateError("文件读取期间已变化，或不是 UTF-8 文本。") }
        return Snapshot(data: bytes, device: after.st_dev, inode: after.st_ino,
                        modified: after.st_mtimespec, changed: after.st_ctimespec, mode: after.st_mode)
    }
    static func equalTime(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && equalTime(a.st_mtimespec, b.st_mtimespec) && equalTime(a.st_ctimespec, b.st_ctimespec)
    }
    static func matches(_ a: Snapshot, _ b: Snapshot) -> Bool {
        a.data == b.data && a.device == b.device && a.inode == b.inode && a.mode == b.mode &&
        equalTime(a.modified, b.modified) && equalTime(a.changed, b.changed)
    }
    static func coordinated<T>(_ url: URL, writing: Bool, body: () throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { _ in
                result = Result { try body() }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in
                result = Result { try body() }
            }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw TemplateError("文件协调失败。") }
        return try result.get()
    }
    static func load(root: URL, file: String, choice: MinisProjectTemplate) throws -> Snapshot {
        try check(file, choice: choice)
        return try coordinated(root.appendingPathComponent(file), writing: false) {
            let (fd, name) = try parent(root, file: file)
            defer { close(fd) }
            return try readAt(fd, name)
        }
    }
    static func validate(_ data: Data, file: String, choice: MinisProjectTemplate, id: UUID) throws {
        guard data.count <= byteLimit, String(data: data, encoding: .utf8) != nil else { throw TemplateError("仅支持不超过 256 KiB 的 UTF-8 文本。") }
        if file == "apelin-project.json" { try ApelinProjectAdapter.validate(data, choice: choice, id: id) }
        if file.hasSuffix(".plist") || file.hasSuffix(".entitlements") {
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        }
    }
    static func save(root: URL, file: String, choice: MinisProjectTemplate, id: UUID,
                     text: String, original: Snapshot) throws -> Snapshot {
        try check(file, choice: choice)
        let data = Data(text.utf8)
        try validate(data, file: file, choice: choice, id: id)
        return try coordinated(root.appendingPathComponent(file), writing: true) {
            let (fd, name) = try parent(root, file: file)
            defer { close(fd) }
            guard try matches(original, readAt(fd, name)) else { throw TemplateError("文件已被其他编辑器修改；请取消并重新打开。") }
            let temporary = ".minis-edit-" + UUID().uuidString
            let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard output >= 0 else { throw TemplateError("无法创建原子保存临时文件。") }
            defer { close(output); unlinkat(fd, temporary, 0) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw TemplateError("写入失败；原文件未替换。") }
                    offset += count
                }
            }
            guard fchmod(output, original.mode & 0o777) == 0, fsync(output) == 0 else { throw TemplateError("临时文件同步失败。") }
            guard try matches(original, readAt(fd, name)) else { throw TemplateError("保存期间文件发生变化；原文件未替换。") }
            guard renameat(fd, temporary, fd, name) == 0 else { throw TemplateError("原子替换失败。") }
            // rename is atomic; coordination excludes cooperating writers. An external
            // non-cooperating writer can still race the final comparison/rename.
            return try readAt(fd, name)
        }
    }
}

// Compile-only adapter for the shipped ObjC CLI's fixed Debug subset. It does
// not bind or rewrite Apelin environment IDs, and never interprets build steps.
enum DevelopmentCLICompileInput {
    static func read(_ file: String, root: URL) throws -> Data {
        let (fd, name) = try DevelopmentProjectEditing.parent(root, file: file)
        defer { close(fd) }
        return try DevelopmentProjectEditing.readAt(fd, name).data
    }
    static func snapshot(root: URL, id: UUID, name: String) throws -> Data {
        let identity = try read("minis-project.json", root: root)
        guard let record = try JSONSerialization.jsonObject(with: identity) as? [String: Any],
              record["schemaVersion"] as? Int == 1, record["id"] as? String == id.uuidString,
              record["name"] as? String == name, record["template"] as? String == "apelin-cli",
              record["target"] as? String == "ios" else { throw TemplateError("项目身份已变化，请重新载入项目。") }
        let data = try read("apelin-project.json", root: root)
        try ApelinProjectAdapter.validate(data, choice: .cli, id: id)
        let (_, project) = try ProjectValidation.load(data)
        guard project.language == .objc, project.deploymentTarget == "16.0", project.products.count == 1,
              project.package.version == "0.0.1" else { throw TemplateError("编译子集仅支持 ObjC CLI、iOS 16.0 和版本 0.0.1。") }
        let product = project.products[0]
        let config = project.configurations.Debug
        guard product.id == "tool", product.type == .executable, product.sources == ["Sources/*.m"],
              product.headerSearchPaths == ["Sources"], product.objcARC == true,
              product.frameworks == ["Foundation"], (product.extensionSupport ?? []).isEmpty,
              (product.frameworkSearchPaths ?? []).isEmpty, (product.librarySearchPaths ?? []).isEmpty,
              (product.libraries ?? []).isEmpty, (product.weakFrameworks ?? []).isEmpty,
              config.optimization == "0", config.debugInfo, config.defines == ["DEBUG": "1"],
              (config.cFlags ?? []).isEmpty, (config.swiftFlags ?? []).isEmpty, (config.linkFlags ?? []).isEmpty,
              project.architectures.rootless?.contains(.arm64) == true else {
            throw TemplateError("此编译入口仅接受原始 ObjC CLI 的固定 Debug 编译配置；自定义搜索路径、参数或扩展暂不支持。")
        }
        let compiles = project.build.steps.filter { $0.typeName == "compile" }
        guard compiles == [.compile(product: "tool", flags: [])],
              !project.build.steps.contains(where: { $0.typeName == "script" }) else {
            throw TemplateError("不支持项目脚本或自定义编译步骤。")
        }
        // No glob is evaluated by a shell. One fixed source is copied, never
        // compiled in-place; external headers and other units are rejected.
        let (sourceFD, _) = try DevelopmentProjectEditing.parent(root, file: "Sources/main.m")
        defer { close(sourceFD) }
        let sourceURL = root.appendingPathComponent("Sources")
        let names = try FileManager.default.contentsOfDirectory(atPath: sourceURL.path)
        guard names == ["main.m"] else { throw TemplateError("当前仅支持 Sources/main.m 单文件；移除额外文件或使用完整 Apelin 后端。") }
        let source = try DevelopmentProjectEditing.readAt(sourceFD, "main.m").data
        guard try read("minis-project.json", root: root) == identity,
              try read("apelin-project.json", root: root) == data else { throw TemplateError("读取期间清单发生变化，请重试。") }
        return source
    }
}
