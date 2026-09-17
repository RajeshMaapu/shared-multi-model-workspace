import Foundation
import WorkshopCore

/// Deterministic scripted adapter shared by tests and the daemon (WORKSHOP_ADAPTERS=fake).
public final class FakeAdapter: EngineerAdapter, @unchecked Sendable {
    /// Thrown when `failAfterDeltas` injects a mid-turn failure.
    public struct InjectedFailure: Error, Equatable {
        public let afterDeltas: Int
    }

    /// A scripted action performed inside a turn (Phase 3 tests).
    public enum ScriptedAction: Sendable {
        /// Call a Workshop tool via `toolRunner` (service.callTool) with the
        /// adapter's own engineer principal.
        case toolCall(String, JSONValue)
        /// Emit a streamed text delta.
        case text(String)
        /// Deterministic provider event for activity contract tests.
        case event(AdapterEvent)
        /// Suspend the stream until this turn is cancelled (pause/cancel tests).
        case waitForCancel
    }

    public let engineer: EngineerID
    public let supportsIsolatedWorkspaceTurns = true
    /// Delay between streamed deltas. 0 in tests.
    public var delayPerDelta: Duration
    /// If set, the stream throws after emitting this many deltas.
    public var failAfterDeltas: Int?
    /// When set, the turn runs these scripted actions instead of the default reply.
    public var script: (@Sendable (TurnContext) async -> [ScriptedAction])?
    /// How scripted tool calls reach the service (set by tests/daemon).
    public var toolRunner: (@Sendable (String, JSONValue, Principal) async throws -> JSONValue)?
    private var scriptedHealth: EngineerHealth

    /// Override the probed health (tests).
    public func setHealth(_ health: EngineerHealth) { scriptedHealth = health }

    private struct State {
        var turnCount = 0
        var probeCount = 0
        var contexts: [TurnContext] = []
        var cancelledTurns: [String] = []
    }
    private let state = Locked(State())

    public init(engineer: EngineerID, delayPerDelta: Duration = .milliseconds(40),
                health: EngineerHealth = .available("Fake adapter ready"),
                failAfterDeltas: Int? = nil) {
        self.engineer = engineer
        self.delayPerDelta = delayPerDelta
        self.failAfterDeltas = failAfterDeltas
        self.scriptedHealth = health
    }

    public var turnCount: Int { state.with { $0.turnCount } }
    public var receivedContexts: [TurnContext] { state.with { $0.contexts } }

    public var probeCount: Int { state.with { $0.probeCount } }

    public func probe() async -> AdapterProbe {
        state.with { $0.probeCount += 1 }
        return AdapterProbe(
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
        let failAfter = failAfterDeltas
        let title = context.task.title
        let engineerName = engineer.displayName
        let script = self.script
        let runner = self.toolRunner
        let principal = Principal.engineer(engineer)
        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.turnStarted)
                var emitted = 0
                func emitDelta(_ text: String) {
                    continuation.yield(.messageDelta(text))
                    emitted += 1
                }
                if let script {
                    for action in await script(context) {
                        switch action {
                        case .toolCall(let name, let args):
                            _ = try? await runner?(name, args, principal)
                        case .event(let event):
                            continuation.yield(event)
                        case .text(let text):
                            emitDelta(text)
                        case .waitForCancel:
                            var waited = 0
                            while !self.state.with({ $0.cancelledTurns.contains(turnID) }),
                                  waited < 1000 {
                                try? await Task.sleep(for: .milliseconds(10))
                                waited += 1
                            }
                            continuation.yield(.turnCompleted)
                            continuation.finish()
                            return
                        }
                    }
                } else {
                    let reply = "Acknowledged \"\(title)\". \(engineerName) has claimed this subtask, " +
                        "reviewed the brief, and will report back with results."
                    // ~6 deltas forming the reply
                    let words = reply.split(separator: " ").map(String.init)
                    let chunkCount = 6
                    let perChunk = max(1, (words.count + chunkCount - 1) / chunkCount)
                    for start in stride(from: 0, to: words.count, by: perChunk) {
                        if let failAfter, emitted >= failAfter {
                            continuation.finish(throwing: InjectedFailure(afterDeltas: failAfter))
                            return
                        }
                        let end = min(start + perChunk, words.count)
                        var chunk = words[start..<end].joined(separator: " ")
                        if end < words.count { chunk += " " }
                        emitDelta(chunk)
                        if delay > .zero {
                            try? await Task.sleep(for: delay)
                        }
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

    /// When false, cancelTurn reports uncertain (no acknowledgement) — T23.
    public var cancelAcknowledged = true

    public func cancelTurn(ref: SessionRef, turnID: String) async -> Bool {
        state.with { $0.cancelledTurns.append(turnID) }
        return cancelAcknowledged
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
    private let reason: String

    public init(engineer: EngineerID, reason: String = "adapter not configured") {
        self.engineer = engineer
        self.reason = reason
    }

    public func probe() async -> AdapterProbe {
        AdapterProbe(
            engineer: engineer,
            health: .unavailable(reason),
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

    public func cancelTurn(ref: SessionRef, turnID: String) async -> Bool { false }
}
