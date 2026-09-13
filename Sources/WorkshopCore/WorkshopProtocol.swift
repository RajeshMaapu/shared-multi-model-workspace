import Foundation

/// JSON-RPC method names and protocol version for the Workshop service.
public enum WorkshopProtocol {
    public static let version = 1

    public static let health = "workshop.health"
    public static let createTask = "workshop.createTask"
    public static let listTasks = "workshop.listTasks"
    public static let getTask = "workshop.getTask"
    public static let readMessages = "workshop.readMessages"
    public static let postMessage = "workshop.postMessage"
    public static let listEngineers = "workshop.listEngineers"
    public static let subscribe = "workshop.subscribe"
    /// Bind a connection to an engineer principal via its capability token.
    public static let authenticate = "workshop.authenticate"
    public static let listArtifacts = "workshop.listArtifacts"
    public static let listUsage = "workshop.listUsage"
    public static let listProposals = "workshop.listProposals"
    public static let listReports = "workshop.listReports"
    public static let listDecisions = "workshop.listDecisions"
    // User-authority actions (Phase 3).
    public static let approveArchitecture = "workshop.approveArchitecture"
    public static let requestChanges = "workshop.requestChanges"
    public static let chooseAlternative = "workshop.chooseAlternative"
    public static let pauseTask = "workshop.pauseTask"
    public static let resumeTask = "workshop.resumeTask"
    public static let cancelTask = "workshop.cancelTask"
    public static let acceptTask = "workshop.acceptTask"
    public static let convertToResearch = "workshop.convertToResearch"

    // Collaboration tool methods (spec §8.3); callable over IPC with an
    // authenticated engineer principal.
    public static let toolGetTask = "workshop_get_task"
    public static let toolReadMessages = "workshop_read_messages"
    public static let toolPostMessage = "workshop_post_message"
    public static let toolRequestReview = "workshop_request_review"
    public static let toolPublishArtifact = "workshop_publish_artifact"
    public static let toolReportResult = "workshop_report_result"
    public static let toolGetCapacity = "workshop_get_capacity"
    public static let toolSaveCheckpoint = "workshop_save_checkpoint"
    public static let toolCreateTask = "workshop_create_task"
    public static let toolProposeSubtask = "workshop_propose_subtask"
    public static let toolClaimSubtask = "workshop_claim_subtask"
    public static let toolAssignSubtask = "workshop_assign_subtask"
    public static let toolSubmitProposal = "workshop_submit_proposal"
    public static let toolReadProposals = "workshop_read_proposals"
    public static let toolSubmitReview = "workshop_submit_review"
    public static let toolSubmitReport = "workshop_submit_report"
    public static let toolDisputeAssignment = "workshop_dispute_assignment"
    public static let toolEscalateTask = "workshop_escalate_task"

    /// Server → client notification carrying a committed outbox event.
    public static let eventNotification = "workshop.event"

    public enum ErrorCode {
        public static let parseError = -32700
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        /// Same idempotency key, different payload.
        public static let idempotencyConflict = -32009
        /// Engineer principal is not a participant of the task.
        public static let notAParticipant = -32003
        /// Caller is not the current owner of the subtask.
        public static let notOwner = -32004
        /// Action reserved to the user principal (or the allocation arbiter).
        public static let userAuthorityRequired = -32005
        /// Substantial task: implementation requires a current approval.
        public static let approvalRequired = -32006
        /// Subtask dependencies are not all done.
        public static let blockedByDependency = -32007
        /// Report revision no longer current (T08).
        public static let staleRevision = -32008
    }
}

/// Error that maps onto a JSON-RPC error code.
public protocol WorkshopRPCError: Error {
    var rpcCode: Int { get }
    var message: String { get }
}

/// ISO-8601 with fractional seconds, UTC.
public enum WorkshopTime {
    public static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(_ string: String) -> Date {
        formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }
}
