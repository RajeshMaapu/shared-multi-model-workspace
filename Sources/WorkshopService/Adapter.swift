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
    /// Extra instruction payload for the wakeup (subtask list, comment, …).
    public var wakeDetail: String?
    /// Note about omitted older messages, if the context was truncated.
    public var truncatedNote: String?

    public init(task: WorkshopTask, subtask: Subtask?, recentMessages: [Message],
                wakeReason: String? = nil, wakeDetail: String? = nil,
                truncatedNote: String? = nil) {
        self.task = task
        self.subtask = subtask
        self.recentMessages = recentMessages
        self.wakeReason = wakeReason
        self.wakeDetail = wakeDetail
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
            let reason = wakeReason.split(separator: ":").first.map(String.init) ?? wakeReason
            switch reason {
            case "mention": lines.append("You were mentioned in the conversation above.")
            case "review_request": lines.append("Your review was requested.")
            case "user_message": lines.append("The user replied; you are the current owner.")
            case "research_proposal":
                lines.append("Research phase: write ONE independent proposal via "
                    + "workshop_submit_proposal {task_id, title, summary, approach, "
                    + "alternatives:[{title, summary}], tradeoffs, sources, risks, "
                    + "proposed_ownership:[{subtask_title, acceptance_criteria, "
                    + "proposed_owner, rationale}], acceptance_tests, estimated_cost}. "
                    + "Peers' drafts are private; do not implement anything.")
            case "cross_review":
                lines.append("All proposals are published. Read them via "
                    + "workshop_read_proposals, then post one review per peer proposal "
                    + "via workshop_submit_review {task_id, proposal_id, severity: "
                    + "low|medium|high, disposition: agree|disagree|needs_changes, "
                    + "body, evidence?}. Preserve disagreement; do not force consensus.")
            case "consolidate":
                lines.append("You are the consolidation arbiter. Read the published "
                    + "proposals and reviews, then call workshop_submit_report {task_id, "
                    + "recommendation, alternatives:[{title, summary}], tradeoffs, sources, "
                    + "disagreements:[{topic, positions:[{engineer, position}]}], "
                    + "proposed_ownership:[{subtask_title, acceptance_criteria, "
                    + "proposed_owner, rationale, risk: normal|high, depends_on:[title]}], "
                    + "risks, acceptance_tests}.")
            case "allocate":
                lines.append("You are the allocation arbiter. Assign every ready subtask "
                    + "via workshop_assign_subtask {task_id, subtask_id, owner, rationale}. "
                    + "You may deviate from the report's proposed owners with rationale. "
                    + "Only assign subtasks whose dependencies are done.")
            case "assigned":
                lines.append("You own this subtask now. Implement it, publish artifacts "
                    + "via workshop_publish_artifact, then call workshop_report_result "
                    + "{task_id, subtask_id, summary, artifact_ids, validation}.")
            case "dispute":
                lines.append("An engineer disputed an assignment; see the decision log "
                    + "and conversation. Reassign via workshop_assign_subtask or explain "
                    + "via workshop_post_message.")
            case "revise_report":
                lines.append("The user requested changes to the consolidated report. "
                    + "Revise it via workshop_submit_report (a new revision).")
            case "verify_result":
                lines.append("Verify the reported result: inspect the published "
                    + "artifacts and validation evidence, then call "
                    + "workshop_submit_review {task_id, proposal_id: <result message id>, "
                    + "severity, disposition: agree|needs_changes, body}. "
                    + "disposition agree = verification passed.")
            case "resumed":
                lines.append("The task was resumed by the user.")
            case "changes_requested":
                lines.append("Verification requested changes on your subtask; "
                    + "address them and report again via workshop_report_result.")
            default: lines.append("Wakeup reason: \(wakeReason)")
            }
            if let wakeDetail, !wakeDetail.isEmpty {
                lines.append("")
                lines.append(wakeDetail)
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
