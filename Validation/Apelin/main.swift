import Foundation

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TemplateError("FAIL: " + message) }
}
func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw TemplateError("FAIL: accepted " + label)
}
let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
print("PASS: actual Swift model + adapter; \(generated) generations, \(fixtureCount) fixtures, digest/plist/binary/identity/path checks")
