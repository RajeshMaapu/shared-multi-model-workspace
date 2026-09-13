import Foundation
import WorkshopCore

/// Deterministic scripted adapter shared by tests and the daemon (WORKSHOP_ADAPTERS=fake).
public final class FakeAdapter: EngineerAdapter, @unchecked Sendable {
    public let engineer: EngineerID
    /// Delay between streamed deltas. 0 in tests.
    public var delayPerDelta: Duration
    private let scriptedHealth: EngineerHealth

    private struct State {
        var turnCount = 0
        var contexts: [TurnContext] = []
        var cancelledTurns: [String] = []
    }
    private let state = Locked(State())

    public init(engineer: EngineerID, delayPerDelta: Duration = .milliseconds(40),
                health: EngineerHealth = .available("Fake adapter ready")) {
        self.engineer = engineer
        self.delayPerDelta = delayPerDelta
        self.scriptedHealth = health
    }

    public var turnCount: Int { state.with { $0.turnCount } }
    public var receivedContexts: [TurnContext] { state.with { $0.contexts } }

    public func probe() async -> AdapterProbe {
        AdapterProbe(
            engineer: engineer,
            health: scriptedHealth,
            versions: ["adapter": "fake-1"],
            effectiveModel: "fake-model",
            capabilities: ["sessions", "streaming", "usage"]
        )
    }

    public func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
        SessionRef(engineer: engineer, nativeSessionID: "fake-session-\(binding.taskID.rawValue)")
    }

    public func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                         deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
        state.with {
            $0.turnCount += 1
            $0.contexts.append(context)
        }
        let delay = delayPerDelta
        let title = context.task.title
        let engineerName = engineer.displayName
        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.turnStarted)
                let reply = "Acknowledged \"\(title)\". \(engineerName) has claimed this subtask, " +
                    "reviewed the brief, and will report back with results."
                // ~6 deltas forming the reply
                let words = reply.split(separator: " ").map(String.init)
                let chunkCount = 6
                let perChunk = max(1, (words.count + chunkCount - 1) / chunkCount)
                for start in stride(from: 0, to: words.count, by: perChunk) {
                    let end = min(start + perChunk, words.count)
                    var chunk = words[start..<end].joined(separator: " ")
                    if end < words.count { chunk += " " }
                    continuation.yield(.messageDelta(chunk))
                    if delay > .zero {
                        try? await Task.sleep(for: delay)
                    }
                }
                continuation.yield(.toolStarted("read_brief"))
                continuation.yield(.toolCompleted("read_brief"))
                continuation.yield(.usageSample(input: 812, output: 140, cacheRead: nil,
                                                cacheWrite: nil, source: "fake"))
                continuation.yield(.turnCompleted)
                continuation.finish()
            }
        }
    }

    public func cancelTurn(ref: SessionRef, turnID: String) async {
        state.with { $0.cancelledTurns.append(turnID) }
    }
}

/// Tiny lock for the adapter's recorded state.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func with<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Adapter used when no real adapter is configured: probes as unavailable, never runs turns.
public struct UnconfiguredAdapter: EngineerAdapter {
    public let engineer: EngineerID

    public init(engineer: EngineerID) {
        self.engineer = engineer
    }

    public func probe() async -> AdapterProbe {
        AdapterProbe(
            engineer: engineer,
            health: .unavailable("adapter not configured"),
            versions: [:],
            effectiveModel: nil,
            capabilities: []
        )
    }

    public func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
        throw WorkshopError.adapterUnavailable(engineer)
    }

    public func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                         deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: WorkshopError.adapterUnavailable(engineer)) }
    }

    public func cancelTurn(ref: SessionRef, turnID: String) async {}
}
