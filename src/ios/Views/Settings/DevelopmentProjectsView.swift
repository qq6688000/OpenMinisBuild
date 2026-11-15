import SwiftUI

private struct DevelopmentProject: Codable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let name: String
    let template: String
    let target: String
    let createdAt: Date
    let buildRecipe: String
}

private enum DevelopmentProjects {
    static let linuxRoot = "/var/minis/shared/projects"
    static let files = ["minis-project.json", "Sources/main.c", "build.sh", "README.md"]
    static var root: URL {
        AIChatViewModel.minisAppGroupRoot.resolvingSymlinksInPath()
            .appendingPathComponent("shared/projects", isDirectory: true)
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "DevelopmentProjects", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func validName(_ name: String) -> Bool {
        name.range(of: "\\A[a-zA-Z][a-zA-Z0-9_-]{0,47}\\z", options: .regularExpression) != nil
    }
    // Reject symlinks, including parent components, before reading or writing.
    static func checkedRoot() throws -> URL {
        let url = root.standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw failure("项目目录包含符号链接，无法安全访问。")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func directory(_ name: String) throws -> URL {
        guard validName(name) else { throw failure("名称须以英文字母开头，只能包含字母、数字、下划线或短横线，最多 48 字符。") }
        let url = try checkedRoot().appendingPathComponent(name, isDirectory: true)
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw failure("项目包含符号链接，无法安全访问。")
        }
        return url
    }
    static func read(_ name: String, file: String) throws -> String {
        var allowed = files
        for choice in MinisProjectTemplate.allCases where choice != .linux {
            allowed += (try? ApelinProjectAdapter.previewFiles(choice)) ?? []
        }
        guard allowed.contains(file) else { throw failure("不支持的项目文件。") }
        let url = try directory(name).appendingPathComponent(file)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.resolvingSymlinksInPath().path == url.path,
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262144 else {
            throw failure("文件不是普通文件、包含符号链接或超过 256 KB。")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func list() throws -> ([DevelopmentProject], [String]) {
        let urls = try FileManager.default.contentsOfDirectory(at: checkedRoot(), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var projects: [DevelopmentProject] = []
        var warnings: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let text = try read(url.lastPathComponent, file: "minis-project.json")
                let project = try JSONDecoder().decode(DevelopmentProject.self, from: Data(text.utf8))
                guard project.schemaVersion == 1, project.name == url.lastPathComponent,
                      let choice = MinisProjectTemplate(rawValue: project.template),
                      project.target == (choice == .linux ? "linux" : "ios"),
                      !projects.contains(where: { $0.id == project.id }) else {
                    throw failure("清单版本、名称、模板或标识无效。")
                }
                if choice != .linux {
                    try ApelinProjectAdapter.validate(Data(read(project.name, file: "apelin-project.json").utf8), choice: choice, id: project.id)
                }
                projects.append(project)
            } catch { warnings.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return (projects, warnings)
    }
    static let source = """
    #include <stdio.h>

    int main(void) {
        puts("Hello from Minis!");
        return 0;
    }
    """ + "\n"
    static let recipe = """
    #!/bin/sh
    set -eu
    cd "$(dirname "$0")"
    mkdir -p build
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror Sources/main.c -o build/hello
    """ + "\n"
    static func create(_ name: String, choice: MinisProjectTemplate = .linux) throws {
        let destination = try directory(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw failure("同名项目或文件已存在，请使用其他名称。")
        }
        let staging = try checkedRoot().appendingPathComponent(".creating-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let project = DevelopmentProject(schemaVersion: 1, id: UUID(), name: name, template: choice.rawValue, target: choice == .linux ? "linux" : "ios", createdAt: Date(), buildRecipe: choice == .linux ? "sh build.sh" : "unconfigured")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: staging.appendingPathComponent("minis-project.json"), options: .atomic)
        if choice != .linux {
            try ApelinProjectAdapter.generate(choice, name: name, id: project.id, into: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            return
        }
        let readme = """
        # \(name)

        C CLI for the Minis Linux shell, not an iOS executable.
        Manifest schema: 1. createdAt uses Foundation seconds since 2001-01-01 UTC.
        Requires a C compiler and libc headers. On Alpine: apk add build-base

        In the Minis terminal:
            cd \(linuxRoot)/\(name)
            sh build.sh
            ./build/hello

        A failed build exits nonzero. The UI does not run builds or install products.
        Build output is build/hello. CC can select another compiler executable.
        Edit Sources/main.c using the terminal or the shared folder in Files.
        """ + "\n"
        for (file, text) in [("Sources/main.c", source), ("build.sh", recipe), ("README.md", readme)] {
            try text.write(to: staging.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

struct DevelopmentProjectsView: View {
    @StateObject private var nativeService = ApelinHelloInspection()
    @State private var projects: [DevelopmentProject] = []
    @State private var warnings: [String] = []
    @State private var name = ""
    @State private var choice: MinisProjectTemplate = .linux
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private func refresh() {
        do { (projects, warnings) = try DevelopmentProjects.list() }
        catch { errorMessage = error.localizedDescription }
    }

    var body: some View {
        List {
            Section("构建后端") {
                Label(nativeService.status, systemImage: "info.circle")
                if nativeService.checking { ProgressView() }
                Button("检查 Apelind（只读 hello）") { nativeService.inspect() }
                    .disabled(nativeService.checking)
                if let snapshot = nativeService.snapshot {
                    Text("协议：\(snapshot.protocolVersion) · 安装根：\(snapshot.installRoot)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let date = nativeService.checkedAt {
                        Text("检查时间：\(date.formatted())").font(.caption)
                    }
                    DisclosureGroup("服务声明的操作（\(snapshot.operations.count)）") {
                        Text(snapshot.operations.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("这是一次握手快照；连接已关闭。操作名称包含尚未实现的能力，不证明 SDK、工具链、构建或安装可用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("上游仅信任安装根下的 Apelin.app/Apelin，并验证 uid、私有 entitlement 和 root 所有权。当前 Minis 分发身份尚未获准；需要独立审核的原生打包与精确 peer 授权，普通沙盒安装不能满足。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("项目文件可正常创建与浏览。此版本仅检查原生 hello，不调用构建、签名或安装服务；可在终端手动构建 Linux C CLI。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Apelin 原生模板仅创建项目：SDK/工具链尚未绑定，iOS 模板面向 rootless/roothide 环境。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("新建项目") {
                Picker("模板", selection: $choice) {
                    ForEach(MinisProjectTemplate.allCases) { item in Text(item.title).tag(item) }
                }
                TextField("项目名称，例如 hello-cli", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("字母开头，最多 48 个字母、数字、下划线或短横线。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("创建项目") {
                    do {
                        try DevelopmentProjects.create(name, choice: choice)
                        name = ""
                        refresh()
                    } catch { errorMessage = error.localizedDescription }
                }.disabled(!DevelopmentProjects.validName(name))
            }
            Section("项目") {
                if projects.isEmpty { Text("暂无项目").foregroundStyle(.secondary) }
                ForEach(projects) { project in
                    NavigationLink(project.name) { DevelopmentProjectDetail(project: project) }
                }
            }
            if !warnings.isEmpty {
                Section("未载入的目录") {
                    ForEach(warnings, id: \.self) { Text($0).font(.caption) }
                }
            }
            Section("文件位置") {
                Text(DevelopmentProjects.linuxRoot).font(.caption.monospaced()).textSelection(.enabled)
                Text("可通过共享文件夹或终端编辑文件；下拉刷新项目列表。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("开发项目")
        .onAppear(perform: refresh)
        .onDisappear { nativeService.cancel() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refresh() }
            else { nativeService.cancel() }
        }
        .refreshable { refresh() }
        .alert("项目操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct DevelopmentProjectDetail: View {
    let project: DevelopmentProject
    private var choice: MinisProjectTemplate { MinisProjectTemplate(rawValue: project.template) ?? .linux }
    private var files: [String] {
        choice == .linux ? DevelopmentProjects.files : ((try? ApelinProjectAdapter.previewFiles(choice)) ?? ["minis-project.json", "apelin-project.json", "README.md"])
    }
    var body: some View {
        List {
            Section("项目信息") {
                Text(choice.title)
                Text("未连接构建后端；没有构建或安装结果。")
                Text(DevelopmentProjects.linuxRoot + "/" + project.name)
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("文件 · 只读预览") {
                ForEach(files, id: \.self) { file in
                    NavigationLink(file) { DevelopmentProjectFile(name: project.name, file: file) }
                }
            }
            if choice == .linux {
            Section("手动构建") {
                Text("cd \(DevelopmentProjects.linuxRoot)/\(project.name)\nsh build.sh\n./build/hello")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("需先安装 C 编译器与 libc 开发头文件，详见 README.md。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            } else {
                Section("原生构建要求") {
                    Text("尚未绑定 SDK 与工具链。此模板需要 Apelin 原生后端、匹配版本的开发扩展及相应签名与运行权限；不能在 iSH Linux 直接构建或安装。")
                    Text("清单已通过上游 schema 与语义规则验证；这不代表环境可用。详见 README.md。")
                }
            }
        }.navigationTitle(project.name)
    }
}

private struct DevelopmentProjectFile: View {
    let name: String
    let file: String
    @State private var content = ""
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(content).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).padding()
        }
        .navigationTitle(file)
        .onAppear {
            do { content = try DevelopmentProjects.read(name, file: file) }
            catch { content = "无法读取文件：\(error.localizedDescription)" }
        }
    }
}
