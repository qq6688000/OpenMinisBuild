// HelloResponse shape adapted from Apelin, MIT; see adjacent LICENSE.
import Foundation
import Combine

struct ApelinHelloSnapshot: Decodable, Equatable {
    let installRoot: String
    let protocolVersion: Int64
    // Upstream explicitly advertises known operations, implemented OR NOT.
    // Keep open strings here so inspection preserves future operation names.
    let operations: [String]

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.protocolVersion == 2 else {
            throw NSError(domain: "MinisApelinHello", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "hello 协议版本不兼容（需要 2）"])
        }
        guard value.installRoot.hasPrefix("/"), !value.installRoot.contains("\0"),
              !value.installRoot.split(separator: "/").contains(".."),
              value.operations.contains("hello"), value.operations.count <= 2048,
              value.operations.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
            throw NSError(domain: "MinisApelinHello", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "hello 的安装根或操作列表无效"])
        }
        return value
    }
}

@MainActor
final class ApelinHelloInspection: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var status = "尚未检查原生服务"
    @Published private(set) var snapshot: ApelinHelloSnapshot?
    @Published private(set) var checkedAt: Date?
    private let transport = MinisApelinHelloTransport()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func inspect() {
        cancel()
        let token = UUID()
        generation = token
        checking = true
        status = "正在连接…"
        task = Task { [weak self] in
            guard let self = self else { return }
            var firstMiss: TimeInterval?
            while !Task.isCancelled && self.generation == token {
                let result: Result<Data, Error> = await withCheckedContinuation { continuation in
                    self.transport.probe { data, error in
                        if let error = error { continuation.resume(returning: .failure(error)) }
                        else if let data = data { continuation.resume(returning: .success(data)) }
                        else { continuation.resume(returning: .failure(NSError(domain: "MinisApelinHello", code: 3))) }
                    }
                }
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    let value = try ApelinHelloSnapshot.decode(result.get())
                    self.snapshot = value
                    self.checkedAt = Date()
                    self.status = "已收到 hello（只读快照）"
                    self.checking = false
                    self.task = nil
                    return
                } catch {
                    let failure = error as NSError
                    let retryable = failure.domain == "MinisApelinHello" && [1, 2].contains(failure.code)
                    let now = ProcessInfo.processInfo.systemUptime
                    if firstMiss == nil { firstMiss = now }
                    if retryable && now - (firstMiss ?? now) < 10 {
                        self.status = "正在连接…\n" + error.localizedDescription
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                        catch { return }
                        continue
                    }
                    self.status = error.localizedDescription
                    self.checking = false
                    self.task = nil
                    return
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        transport.cancel()
        checking = false
        snapshot = nil
        checkedAt = nil
        status = "尚未检查原生服务"
    }
}
