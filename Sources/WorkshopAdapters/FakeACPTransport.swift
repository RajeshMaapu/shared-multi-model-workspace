import Foundation
import WorkshopCore

/// Scripted ACP transport for deterministic tests. `responder` maps each sent
/// request line to zero or more reply lines (responses, notifications, or
/// server→client requests). All sent lines are recorded.
public final class FakeACPTransport: ACPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) public var sentLines: [String] = []
    private var continuation: AsyncStream<String>.Continuation?
    private let responder: @Sendable (String) -> [String]
    public let lines: AsyncStream<String>
    public private(set) var terminated = false

    public init(responder: @escaping @Sendable (String) -> [String]) {
        self.responder = responder
        var cont: AsyncStream<String>.Continuation!
        lines = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func send(_ line: String) throws {
        lock.lock()
        sentLines.append(line)
        let replies = responder(line)
        lock.unlock()
        for reply in replies { continuation?.yield(reply) }
    }

    /// Inject a line as if the harness sent it (notifications, requests).
    public func inject(_ line: String) {
        continuation?.yield(line)
    }

    /// Close the line stream.
    public func finish() { continuation?.finish() }

    public func terminate() {
        lock.lock(); terminated = true; lock.unlock()
        continuation?.finish()
    }
}
