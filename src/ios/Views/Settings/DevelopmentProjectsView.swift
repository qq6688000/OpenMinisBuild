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
    @StateObject private var local = DevelopmentLocalToolchainState()
    @State private var projects: [DevelopmentProject] = []
    @State private var warnings: [String] = []
    @State private var name = ""
    @State private var choice: MinisProjectTemplate = .cli
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private func refresh() {
        do { (projects, warnings) = try DevelopmentProjects.list() }
        catch { errorMessage = error.localizedDescription }
    }

    var body: some View {
        List {
            DevelopmentLocalToolchainSection(local: local)
            Section("Apelin 服务（可选）") {
                Text("ObjC CLI 使用上方 Minis 本地后端，无需 Apelind。若服务不可用，不影响本地初始化。")
                    .font(.footnote)
                DisclosureGroup("Apelin 状态与诊断") {
                    Label(nativeService.status, systemImage: "info.circle")
                    if nativeService.checking { ProgressView() }
                    Button("检查 Apelind、SDK 与工具链（只读）") { nativeService.inspect() }
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
                    Text(nativeService.environmentStatus).font(.caption)
                    if let sdks = nativeService.sdks {
                        DisclosureGroup("已注册 SDK（\(sdks.sdks.count)）；活动任务 \(sdks.activeTasks.count)") {
                            ForEach(Array(sdks.sdks.enumerated()), id: \.offset) { _, sdk in
                                Text("\(sdk.canonicalName) · \(sdk.version)\n\(sdk.path)\n\(sdk.warnings.joined(separator: "\n"))")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if let status = nativeService.toolchains {
                        DisclosureGroup("已注册工具链（\(status.toolchains.count)）；活动任务 \(status.activeTasks.count)") {
                            Text("默认：\(status.defaultID ?? "未设置")").font(.caption)
                            ForEach(Array(status.toolchains.enumerated()), id: \.offset) { _, tool in
                                Text("\(tool.id) · \(tool.version)\n\(tool.path ?? "未记录路径")")
                                    .font(.caption).textSelection(.enabled)
                                ForEach(Array(tool.components.enumerated()), id: \.offset) { _, component in
                                    Text("\(component.kind)：历史自检 \(component.selfCheckPassed.map { $0 ? "通过" : "失败" } ?? "未记录") \(component.problem ?? "")")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    Text("需要经过审核的 Apelin 伴生部署与固定路径 Minis 客户端。当前 TrollStore 容器安装不满足其路径认证；添加 entitlement 本身不能解决。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Apelin 连接仅读取 hello、SDK 与工具链注册记录。Linux C CLI 可在终端手动构建。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("App、Tweak 和 Preferences 模板目前仅创建项目；Apelin SDK / 工具链绑定独立于 Minis 本地后端。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("新建项目") {
                Text("选择 ObjC CLI · iOS → 输入名称 → 创建项目 → 打开项目 → 检测本地工具链 → Build+Link。")
                    .font(.footnote)
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
                    NavigationLink(project.name) { DevelopmentProjectDetail(project: project, local: local) }
                }
            }
            if !warnings.isEmpty {
                Section("未载入的目录") {
                    ForEach(warnings, id: \.self) { Text($0).font(.caption) }
                }
            }
            Section("文件位置") {
                Text(DevelopmentProjects.linuxRoot).font(.caption.monospaced()).textSelection(.enabled)
                Text("打开项目文件可直接编辑并保存；也可使用共享文件夹或终端。下拉刷新项目列表。")
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
    @ObservedObject var local: DevelopmentLocalToolchainState
    @StateObject private var build = DevelopmentCLICompileState()
    @Environment(\.scenePhase) private var scenePhase
    private var choice: MinisProjectTemplate { MinisProjectTemplate(rawValue: project.template) ?? .linux }
    private var files: [String] {
        choice == .linux ? DevelopmentProjects.files : ((try? ApelinProjectAdapter.previewFiles(choice)) ?? ["minis-project.json", "apelin-project.json", "README.md"])
    }
    var body: some View {
        List {
            Section("项目信息") {
                Text(choice.title)
                Text(choice == .cli ? "可提交 Minis 原生 Debug Build+Link；产物为 arm64 iOS unsigned executable，未签名或安装，不保证设备可运行。" : "此模板尚未接入构建操作。")
                Text(DevelopmentProjects.linuxRoot + "/" + project.name)
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            if choice == .cli {
                DevelopmentLocalToolchainSection(local: local, building: build.running)
                Section("Minis 原生编译") {
                    Text("Sources/main.m · arm64 · iOS 16.0 · ARC。先通过文件检查与启动探测，再编译链接。产物不会自动运行。")
                        .font(.footnote)
                    Button("Build+Link · ObjC CLI") { build.start(project) }.disabled(build.running || local.running || !local.canBuild)
                    if build.running {
                        ProgressView()
                        Button("取消编译", role: .destructive) { build.cancel() }
                    }
                    Text(build.status).font(.caption).textSelection(.enabled)
                    if !build.log.isEmpty {
                        DisclosureGroup("编译日志 / 状态（最多 128 KiB）") {
                            Text(build.log).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            Section("项目文件") {
                ForEach(files, id: \.self) { file in
                    NavigationLink(file) { DevelopmentProjectFile(project: project, file: file) }
                }
                Text("源文件、Apelin 清单、plist、构建脚本与 README 可编辑；身份和来源记录只读。UTF-8 文件上限 256 KiB。保存不会构建或安装。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if choice == .linux {
            Section("手动构建") {
                Text("cd \(DevelopmentProjects.linuxRoot)/\(project.name)\nsh build.sh\n./build/hello")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("需先安装 C 编译器与 libc 开发头文件，详见 README.md。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            } else if choice != .cli {
                Section("原生构建要求") {
                    Text("尚未绑定 SDK 与工具链。此模板需要 Apelin 原生后端、匹配版本的开发扩展及相应签名与运行权限；不能在 iSH Linux 直接构建或安装。")
                    Text("清单已通过上游 schema 与语义规则验证；这不代表环境可用。详见 README.md。")
                }
            }
        }.navigationTitle(project.name)
            .onDisappear { build.cancel() }
            .onChange(of: scenePhase) { phase in if phase != .active { build.cancel() } }
    }
}

@MainActor
private final class DevelopmentCLICompileState: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "尚未提交编译"
    @Published private(set) var log = ""
    private let native = MinisNativeCLICompile()
    private var bytes = Data()
    func start(_ project: DevelopmentProject) {
        guard !running else { return }
        do {
            let root = try DevelopmentProjects.directory(project.name)
            let source = try DevelopmentCLICompileInput.snapshot(root: root, id: project.id, name: project.name)
            running = true; status = "已提交：检查本机编译器 / SDK，然后编译…"; bytes = Data(); log = ""
            native.compile(source: source, output: { [weak self] chunk in
                guard let self = self else { return }
                self.bytes.append(chunk)
                self.log = String(decoding: self.bytes, as: UTF8.self)
            }, completion: { [weak self] report in
                guard let self = self else { return }
                self.running = false
                self.status = (report["ok"] as? Bool == true) ? "Build+Link 成功：arm64 iOS unsigned executable 已验证；未签名或安装，不代表可在设备运行。" : "编译未完成：\(report["error"] ?? "未知错误")"
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    self.log += "\n" + String(decoding: data, as: UTF8.self)
                }
            })
        } catch { status = "未提交：" + error.localizedDescription }
    }
    func cancel() {
        guard running else { return }
        status = "正在请求取消；等待原生进程回收…"
        native.cancel()
    }
}

private struct DevelopmentProjectFile: View {
    let project: DevelopmentProject
    let file: String
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var original: DevelopmentProjectEditing.Snapshot?
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var discard = false
    private var choice: MinisProjectTemplate { MinisProjectTemplate(rawValue: project.template) ?? .linux }
    private var editable: Bool { ((try? DevelopmentProjectEditing.editableFiles(choice)) ?? []).contains(file) }
    private var dirty: Bool { original.map { content != $0.text } ?? false }
    private var tooLarge: Bool { content.utf8.count > DevelopmentProjectEditing.byteLimit }
    private func load() {
        guard !loaded else { return }
        do {
            if editable {
                let snapshot = try DevelopmentProjectEditing.load(root: DevelopmentProjects.directory(project.name), file: file, choice: choice)
                original = snapshot
                content = snapshot.text
            } else { content = try DevelopmentProjects.read(project.name, file: file) }
            loaded = true
        } catch { errorMessage = error.localizedDescription }
    }
    private func save() {
        guard let original = original else { return }
        do {
            self.original = try DevelopmentProjectEditing.save(root: DevelopmentProjects.directory(project.name), file: file,
                choice: choice, id: project.id, text: content, original: original)
        } catch { errorMessage = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editable {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!loaded)
                    .accessibilityLabel("编辑 \(file)")
                Text("\(dirty ? "未保存" : "已保存") · \(content.utf8.count) / 262144 字节")
                    .font(.caption).foregroundColor(tooLarge ? .red : .secondary)
                if tooLarge { Text("内容超过 256 KiB，无法保存。").font(.caption).foregroundColor(.red) }
            } else {
                Text("身份与来源记录 · 只读").font(.caption).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .padding()
        .navigationTitle(file)
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if editable {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { if dirty { discard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存", action: save).disabled(!loaded || !dirty || tooLarge)
                }
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("放弃未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .alert("文件操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

// The native adapter owns background work and returns on the main queue.
@MainActor
private final class DevelopmentLocalToolchainState: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var filesReady = false
    @Published private(set) var spawnVerified = false
    @Published private(set) var status = "尚未检测本地工具链"
    @Published private(set) var diagnostic = ""
    private let native = MinisNativeLocalToolchain()
    var canBuild: Bool { filesReady && spawnVerified && !running }
    func perform(_ operation: NBLocalToolchainOperation) {
        guard !running else { return }
        running = true
        filesReady = false
        spawnVerified = false
        status = operation == .provision ? "正在初始化归档，请保持 Minis 在前台…" : "正在检测本地工具链…"
        native.perform(operation: operation) { [weak self] report in
            guard let self = self else { return }
            self.running = false
            self.filesReady = report["files_ready"] as? Bool == true
            self.spawnVerified = report["spawn_verified"] as? Bool == true
            if let provision = report["provision"] as? [String: Any], provision["ok"] as? Bool != true {
                self.filesReady = false
                self.status = "初始化未完成；展开诊断查看归档错误，然后重试。"
            } else if operation == .probe {
                self.status = self.canBuild ? "clang / ld 启动探测通过；可提交 Build+Link。" : "检测未通过；查看诊断，可重新初始化或重试探测。"
            } else {
                self.status = self.filesReady ? "文件就绪；请继续运行启动探测。" : "文件尚未就绪；请初始化本地 SDK 与工具链。"
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                self.diagnostic = String(decoding: data, as: UTF8.self)
            }
        }
    }
}

private struct DevelopmentLocalToolchainSection: View {
    @ObservedObject var local: DevelopmentLocalToolchainState
    var building = false
    var body: some View {
        Section("Minis 本地后端 · ObjC CLI") {
            Text("独立使用随包 SDK 与工具链，无需 Apelind。")
                .font(.footnote)
            Text(local.status).font(.caption).textSelection(.enabled)
            if local.running { ProgressView() }
            Group {
                Button("检测本地文件（不启动工具）") { local.perform(.inspect) }
                Button("初始化 / 修复本地 SDK 与工具链") { local.perform(.provision) }
                Button("启动探测 clang / ld（可重试）") { local.perform(.probe) }
            }.disabled(local.running || building)
            DisclosureGroup("本地诊断与说明") {
                Text("文件检查只证明路径就绪；启动探测执行 clang / ld --version；只有项目 Build+Link 成功才验证编译和链接。初始化只展开随包归档。此处不签名、安装或运行产物。")
                    .font(.caption)
                Text(local.diagnostic).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}
