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
    /// The subtask this turn is about; nil for pure discussion wakeups.
    public var subtask: Subtask?
    /// Messages after the engineer's consumed cursor, already bounded.
    public var recentMessages: [Message]
    /// Why this turn was woken (nil = owner-execution turn).
    public var wakeReason: String?
    /// Note about omitted older messages, if the context was truncated.
    public var truncatedNote: String?

    public init(task: WorkshopTask, subtask: Subtask?, recentMessages: [Message],
                wakeReason: String? = nil, truncatedNote: String? = nil) {
        self.task = task
        self.subtask = subtask
        self.recentMessages = recentMessages
        self.wakeReason = wakeReason
        self.truncatedNote = truncatedNote
    }

    /// Render the turn context packet (spec §G): stable header, task brief,
    /// unseen messages, wakeup reason.
    public func packetText(for engineer: EngineerID) -> String {
        var lines: [String] = []
        lines.append("# Workshop")
        lines.append("You are \(engineer.displayName), one of three AI engineers in a "
            + "local macOS community workspace: Devin, Kimi, and DeepSeek.")
        lines.append("Use workshop_post_message to speak; mention @devin, @kimi, or "
            + "@deepseek to wake a peer. Do not post secrets.")
        lines.append("The task_id for Workshop tool calls is \(task.id.rawValue).")
        if let subtask {
            lines.append("You are owner/participant of subtask \(subtask.id.rawValue) "
                + "\"\(subtask.title)\" (generation \(subtask.generation)).")
        } else {
            lines.append("You are a participant of this task (no owned subtask).")
        }
        lines.append("")
        lines.append("## Task: \(task.title)")
        lines.append(task.brief)
        if let subtask, !subtask.acceptance.isEmpty {
            lines.append("Acceptance: " + subtask.acceptance.joined(separator: "; "))
        }
        if let truncatedNote { lines.append("(\(truncatedNote))") }
        if !recentMessages.isEmpty {
            lines.append("")
            lines.append("## Conversation")
            for m in recentMessages where m.deliveryState == .committed {
                lines.append("[\(m.seq)] \(m.author.displayName): \(m.body)")
            }
        }
        if let wakeReason {
            lines.append("")
            switch wakeReason {
            case "mention": lines.append("You were mentioned in the conversation above.")
            case "review_request": lines.append("Your review was requested.")
            case "user_message": lines.append("The user replied; you are the current owner.")
            default: lines.append("Wakeup reason: \(wakeReason)")
            }
        }
        return lines.joined(separator: "\n")
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
    /// A non-message tool activity update (title + status) for UI display.
    case toolActivity(title: String, status: String)
    /// A tool call was denied by the permission policy (Phase 3 adds user cards).
    case permissionDenied(String)
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
