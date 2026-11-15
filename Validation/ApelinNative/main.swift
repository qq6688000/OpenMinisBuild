import Foundation

func expectReject(_ text: String) {
    do {
        _ = try ApelinHelloSnapshot.decode(Data(text.utf8))
        fatalError("Unexpected acceptance: \(text)")
    } catch {}
}

let valid = Data(#"{"installRoot":"/var/jb","protocolVersion":2,"operations":["hello","futureOperation","buildStart"]}"#.utf8)
let hello = try ApelinHelloSnapshot.decode(valid)
precondition(hello.installRoot == "/var/jb")
precondition(hello.operations == ["hello", "futureOperation", "buildStart"])
for root in ["/", "/private/var/containers/Bundle/Application/.jbroot-0123456789abcdef"] {
    let data = try JSONSerialization.data(withJSONObject: ["installRoot": root, "protocolVersion": 2, "operations": ["hello"]])
    let decoded = try ApelinHelloSnapshot.decode(data)
    precondition(decoded.installRoot == root)
}
expectReject(#"{"installRoot":"/var/jb","protocolVersion":1,"operations":["hello"]}"#)
expectReject(#"{"installRoot":"relative","protocolVersion":2,"operations":["hello"]}"#)
expectReject(#"{"installRoot":"/var/../jb","protocolVersion":2,"operations":["hello"]}"#)
expectReject(#"{"installRoot":"/var/\u0000jb","protocolVersion":2,"operations":["hello"]}"#)
expectReject(#"{"installRoot":"/","protocolVersion":2,"operations":["buildStart"]}"#)
expectReject(#"{"installRoot":"/","protocolVersion":2,"operations":["hello",""]}"#)
expectReject(#"{"installRoot":"/","protocolVersion":2,"operations":"hello"}"#)
expectReject(#"{"installRoot":"/","operations":["hello"]}"#)
expectReject("not JSON")

// Compile and exercise the real Objective-C bridge against a bounded read-only
// Mach lookup on macOS. Either completion/cancellation wins; it must fire once.
let transport = MinisApelinHelloTransport()
var completions = 0
transport.probe { _, _ in completions += 1 }
transport.cancel()
let end = Date().addingTimeInterval(6)
while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
precondition(completions == 1, "reply/timeout/cancel must claim completion once")
print("PASS: actual hello decoder and real bridge one-shot cancellation; not iOS daemon authorization")
