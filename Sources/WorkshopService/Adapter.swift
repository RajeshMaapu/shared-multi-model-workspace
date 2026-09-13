import Foundation
import WorkshopCore

/// Reference to an open native (or fake) session.
public struct SessionRef: Codable, Equatable, Sendable {
    public var engineer: EngineerID
    public var nativeSessionID: String

    public init(engineer: EngineerID, nativeSessionID: String) {
        self.engineer = engineer
        self.nativeSessionID = nativeSessionID
    }
}

/// Session binding persisted per (task, engineer, role, worker) (spec §6.2).
public struct SessionBinding: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var engineerID: EngineerID
    public var role: String
    public var workerID: String
    public var nativeSessionID: String?
    public var profileRevision: Int
    public var modelSelection: String?
    public var recoveryState: String

    public init(taskID: TaskID, engineerID: EngineerID, role: String, workerID: String,
                nativeSessionID: String? = nil, profileRevision: Int = 1,
                modelSelection: String? = nil, recoveryState: String = "new") {
        self.taskID = taskID
        self.engineerID = engineerID
        self.role = role
        self.workerID = workerID
        self.nativeSessionID = nativeSessionID
        self.profileRevision = profileRevision
        self.modelSelection = modelSelection
        self.recoveryState = recoveryState
    }
}

/// Context handed to an adapter for one turn.
public struct TurnContext: Sendable {
    public var task: WorkshopTask
    public var subtask: Subtask
    public var recentMessages: [Message]

    public init(task: WorkshopTask, subtask: Subtask, recentMessages: [Message]) {
        self.task = task
        self.subtask = subtask
        self.recentMessages = recentMessages
    }
}

/// Normalized adapter stream events (spec §7.1).
public enum AdapterEvent: Sendable, Equatable {
    case turnStarted
    case messageDelta(String)
    case toolStarted(String)
    case toolCompleted(String)
    case usageSample(input: Int?, output: Int?, cacheRead: Int?, cacheWrite: Int?, source: String)
    case checkpointReady
    case turnCompleted
    case authRequired
    case quotaLimited
    case uncertain(String)
}

/// One engineer harness adapter (spec §7.1).
public protocol EngineerAdapter: Sendable {
    var engineer: EngineerID { get }
    func probe() async -> AdapterProbe
    func openTaskSession(binding: SessionBinding) async throws -> SessionRef
    func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                  deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error>
    func cancelTurn(ref: SessionRef, turnID: String) async
}
