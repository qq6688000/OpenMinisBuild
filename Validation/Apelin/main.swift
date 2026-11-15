import Foundation

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TemplateError("FAIL: " + message) }
}
func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TemplateError("FAIL: accepted " + label)
}
let fm = FileManager.default
let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }
let resources = try ApelinProjectAdapter.resources
try require(fm.fileExists(atPath: resources.path), "Bundle.main resources")
var generated = 0
for choice in MinisProjectTemplate.allCases where choice != .linux {
    let (root, _, template) = try ApelinProjectAdapter.descriptor(choice)
    let templateRoot = root.appendingPathComponent(template.directory)
    let actualDigest = try TemplateDigest.compute(templateRoot: templateRoot, files: template.files)
    try require(actualDigest == template.digest, "template digest")
    for name in ["Hello", "hello-cli", "Hello_42", "A" + String(repeating: "b", count: 47)] {
        let destination = scratch.appendingPathComponent(choice.rawValue + name)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let id = UUID()
        try ApelinProjectAdapter.generate(choice, name: name, id: id, into: destination)
        let data = try ProjectFiles.read("apelin-project.json", in: destination)
        try ApelinProjectAdapter.validate(data, choice: choice, id: id)
        if choice == .cli {
            let identity: [String: Any] = ["schemaVersion": 1, "id": id.uuidString, "name": name, "template": "apelin-cli", "target": "ios"]
            try JSONSerialization.data(withJSONObject: identity).write(to: destination.appendingPathComponent("minis-project.json"))
            let source = try DevelopmentCLICompileInput.snapshot(root: destination, id: id, name: name)
            try require(source == (try ProjectFiles.read("Sources/main.m", in: destination)), "compile snapshot")
            try rejects("compile wrong identity") { _ = try DevelopmentCLICompileInput.snapshot(root: destination, id: UUID(), name: name) }
            let extra = destination.appendingPathComponent("Sources/extra.m")
            try Data("int extra;".utf8).write(to: extra)
            try rejects("extra compile translation unit") { _ = try DevelopmentCLICompileInput.snapshot(root: destination, id: id, name: name) }
            try fm.removeItem(at: extra)
            let original = try StrictJSON.parse(data)
            for (needle, replacement) in [("\"optimization\": \"0\"", "\"optimization\": \"1\""), ("\"deploymentTarget\": \"16.0\"", "\"deploymentTarget\": \"17.0\"")] {
                let changed = String(decoding: data, as: UTF8.self).replacingOccurrences(of: needle, with: replacement)
                try require(changed != String(decoding: data, as: UTF8.self), "negative compile fixture changed")
                try Data(changed.utf8).write(to: destination.appendingPathComponent("apelin-project.json"))
                try rejects("unsupported compile configuration") { _ = try DevelopmentCLICompileInput.snapshot(root: destination, id: id, name: name) }
            }
            _ = original
            try data.write(to: destination.appendingPathComponent("apelin-project.json"))
            let target = destination.appendingPathComponent("Sources/main.m")
            let copy = destination.appendingPathComponent("main-copy.m")
            try fm.moveItem(at: target, to: copy)
            try fm.createSymbolicLink(at: target, withDestinationURL: copy)
            try rejects("compile symlink source") { _ = try DevelopmentCLICompileInput.snapshot(root: destination, id: id, name: name) }
            try fm.removeItem(at: target)
            try fm.moveItem(at: copy, to: target)
        }
        try rejects("wrong UUID") { try ApelinProjectAdapter.validate(data, choice: choice, id: UUID()) }
        for file in template.files {
            let bytes = try ProjectFiles.read(file.path, in: destination)
            if file.format == "copy" {
                let original = try ProjectFiles.read(file.path, in: templateRoot)
                try require(bytes == original, "binary copy")
            } else {
                try require(!(String(data: bytes, encoding: .utf8) ?? "{{").contains("{{"), "unresolved token")
                if file.format == "plist-xml" {
                    _ = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
                }
            }
        }
        let copiedLicense = try ProjectFiles.read("APELIN-LICENSE.txt", in: destination)
        let originalLicense = try ProjectFiles.read("LICENSE", in: root)
        try require(copiedLicense == originalLicense, "license")
        generated += 1
    }
}
for text in ["{\"x\":1,\"x\":2}", "{\"x\":1.5}", "\u{feff}{}"] {
    try rejects("invalid strict JSON") { _ = try StrictJSON.parse(Data(text.utf8)) }
}
for path in ["../escape", "/absolute", "a//b", "a/./b", "a\\b", "a\0b"] {
    try rejects("unsafe path \(path)") { _ = try ProjectFiles.checkedURL(path, in: scratch) }
}
try Data(repeating: 1, count: 262145).write(to: scratch.appendingPathComponent("large"))
try rejects("oversized file") { _ = try ProjectFiles.read("large", in: scratch) }
try fm.createSymbolicLink(at: scratch.appendingPathComponent("link"), withDestinationURL: resources)
try rejects("symlink descendant") { _ = try ProjectFiles.read("link/PROVENANCE.json", in: scratch) }
try rejects("invalid project name") {
    try ApelinProjectAdapter.generate(.cli, name: "../escape", id: UUID(), into: scratch)
}
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
var fixtureCount = 0
for category in ["project", "extension"] {
    for validity in ["valid", "invalid"] {
        let directory = fixtures.appendingPathComponent(category + "/" + validity)
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && file.lastPathComponent != "expectations.json" {
            let document = try StrictJSON.parse(Data(contentsOf: file))
            let errors = category == "project" ? ProjectValidation.errors(document) : ManifestValidation.errors(document)
            try require(errors.isEmpty == (validity == "valid"), "fixture \(file.path): \(errors)")
            fixtureCount += 1
        }
    }
}
// Exercise the exact editor store, not a Python reimplementation.
for choice in MinisProjectTemplate.allCases {
    let destination = scratch.appendingPathComponent("edit-" + choice.rawValue)
    try fm.createDirectory(at: destination.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    let id = UUID()
    if choice == .linux {
        try Data("hello\n".utf8).write(to: destination.appendingPathComponent("Sources/main.c"))
        try Data("#!/bin/sh\n".utf8).write(to: destination.appendingPathComponent("build.sh"))
        try Data("README\n".utf8).write(to: destination.appendingPathComponent("README.md"))
    } else { try ApelinProjectAdapter.generate(choice, name: "Editor", id: id, into: destination) }
    for file in try DevelopmentProjectEditing.editableFiles(choice) {
        let before = try DevelopmentProjectEditing.load(root: destination, file: file, choice: choice)
        let saved = try DevelopmentProjectEditing.save(root: destination, file: file, choice: choice, id: id,
                                                      text: before.text + "\n", original: before)
        try require(saved.data == Data((before.text + "\n").utf8), "atomic edit roundtrip \(file)")
        try require(saved.inode != before.inode && saved.mode == before.mode, "atomic replacement/mode")
        try rejects("stale editor snapshot") {
            _ = try DevelopmentProjectEditing.save(root: destination, file: file, choice: choice, id: id,
                                                  text: before.text, original: before)
        }
    }
    let source = choice == .linux ? "Sources/main.c" : (try DevelopmentProjectEditing.editableFiles(choice)).first(where: { $0.hasPrefix("Sources/") })!
    let before = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice)
    try rejects("UTF-8 byte limit") {
        _ = try DevelopmentProjectEditing.save(root: destination, file: source, choice: choice, id: id,
                                              text: String(repeating: "é", count: 131073), original: before)
    }
    try require(try Data(contentsOf: destination.appendingPathComponent(source)) == before.data, "failed save retains original")
    if choice != .linux {
        let manifest = try DevelopmentProjectEditing.load(root: destination, file: "apelin-project.json", choice: choice)
        for invalid in ["{}", "{\"x\":1,\"x\":2}", manifest.text.replacingOccurrences(of: id.uuidString.lowercased(), with: UUID().uuidString.lowercased())] {
            try rejects("manifest schema/identity") {
                _ = try DevelopmentProjectEditing.save(root: destination, file: "apelin-project.json", choice: choice, id: id, text: invalid, original: manifest)
            }
        }
        try require(try Data(contentsOf: destination.appendingPathComponent("apelin-project.json")) == manifest.data, "rejected manifest unchanged")
    }
    for file in ["../escape", "/absolute", "Sources/../main.c", "Sources//main.c", "Sources\\main.c", "minis-project.json", "APELIN-PROVENANCE.json", "unknown.m"] {
        try rejects("unsupported edit \(file)") { _ = try DevelopmentProjectEditing.load(root: destination, file: file, choice: choice) }
    }
    if let plist = try DevelopmentProjectEditing.editableFiles(choice).first(where: { $0.hasSuffix(".plist") || $0.hasSuffix(".entitlements") }) {
        let snapshot = try DevelopmentProjectEditing.load(root: destination, file: plist, choice: choice)
        try rejects("invalid plist") {
            _ = try DevelopmentProjectEditing.save(root: destination, file: plist, choice: choice, id: id, text: "<broken", original: snapshot)
        }
        try require(try Data(contentsOf: destination.appendingPathComponent(plist)) == snapshot.data, "invalid plist unchanged")
    }
    let target = destination.appendingPathComponent(source)
    let hardLink = destination.appendingPathComponent("hard-link")
    try fm.linkItem(at: target, to: hardLink)
    try rejects("hard link") { _ = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice) }
    try fm.removeItem(at: hardLink)
    try Data("external edit".utf8).write(to: target)
    try rejects("external writer conflict") {
        _ = try DevelopmentProjectEditing.save(root: destination, file: source, choice: choice, id: id, text: "overwrite", original: before)
    }
    try fm.removeItem(at: target)
    try fm.createSymbolicLink(at: target, withDestinationURL: resources.appendingPathComponent("PROVENANCE.json"))
    try rejects("leaf symlink") { _ = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice) }
    try rejects("symlink save") {
        _ = try DevelopmentProjectEditing.save(root: destination, file: source, choice: choice, id: id, text: "overwrite", original: before)
    }
    try fm.removeItem(at: target)
    try fm.createDirectory(at: target, withIntermediateDirectories: false)
    try rejects("directory as file") { _ = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice) }
    try fm.removeItem(at: target)
    try Data([0xff]).write(to: target)
    try rejects("non UTF-8") { _ = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice) }
    try Data(repeating: 65, count: 262145).write(to: target)
    try rejects("oversize read") { _ = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice) }
    try Data(repeating: 65, count: 262144).write(to: target)
    let limit = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice)
    _ = try DevelopmentProjectEditing.save(root: destination, file: source, choice: choice, id: id, text: limit.text, original: limit)
    let alias = scratch.appendingPathComponent("alias-" + choice.rawValue)
    try fm.createSymbolicLink(at: alias, withDestinationURL: destination)
    try rejects("symlink project root") { _ = try DevelopmentProjectEditing.load(root: alias, file: source, choice: choice) }
    let sources = destination.appendingPathComponent("Sources")
    let moved = destination.appendingPathComponent("MovedSources")
    try fm.moveItem(at: sources, to: moved)
    try fm.createSymbolicLink(at: sources, withDestinationURL: moved)
    try rejects("symlink parent") { _ = try DevelopmentProjectEditing.load(root: destination, file: source, choice: choice) }
}
print("PASS: actual Swift model + adapter; \(generated) generations, \(fixtureCount) fixtures, digest/plist/binary/identity/path checks; editor roundtrips/conflicts/schema/size/symlink/UTF-8 negatives for all five templates")
