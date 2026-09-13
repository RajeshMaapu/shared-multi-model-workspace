import Foundation
import WorkshopCore

public enum WorkshopError: WorkshopRPCError, Equatable {
    /// Same idempotency key reused with a different payload (JSON-RPC -32009).
    case idempotencyConflict
    case invalidRequest(String)
    case methodNotFound(String)
    case taskNotFound(TaskID)
    case illegalTransition(from: TaskState, to: TaskState)
    case adapterUnavailable(EngineerID)
    /// Engineer principal is not a participant of the task (-32003).
    case notAParticipant(engineer: EngineerID, task: TaskID)
    /// Caller is not the current owner at the current generation (-32004).
    case notOwner
    /// Path escapes the task workspace.
    case workspaceEscape(String)
    /// Tool intentionally unimplemented in this phase.
    case phaseNotImplemented(String)
    /// Reserved to the user principal (or the allocation arbiter) (-32005).
    case userAuthorityRequired(String)
    /// Substantial task lacks a current approval (-32006).
    case approvalRequired(TaskID)
    /// Subtask dependencies are not all done (-32007).
    case blockedByDependency(SubtaskID)
    /// Report revision no longer current (-32008, T08).
    case staleRevision(expected: Int, actual: Int?)

    /// JSON-RPC error code for this failure.
    public var rpcCode: Int {
        switch self {
        case .idempotencyConflict:
            return WorkshopProtocol.ErrorCode.idempotencyConflict
        case .invalidRequest:
            return WorkshopProtocol.ErrorCode.invalidParams
        case .methodNotFound:
            return WorkshopProtocol.ErrorCode.methodNotFound
        case .taskNotFound:
            return WorkshopProtocol.ErrorCode.invalidParams
        case .notAParticipant:
            return WorkshopProtocol.ErrorCode.notAParticipant
        case .notOwner:
            return WorkshopProtocol.ErrorCode.notOwner
        case .workspaceEscape:
            return WorkshopProtocol.ErrorCode.invalidParams
        case .phaseNotImplemented:
            return WorkshopProtocol.ErrorCode.methodNotFound
        case .userAuthorityRequired:
            return WorkshopProtocol.ErrorCode.userAuthorityRequired
        case .approvalRequired:
            return WorkshopProtocol.ErrorCode.approvalRequired
        case .blockedByDependency:
            return WorkshopProtocol.ErrorCode.blockedByDependency
        case .staleRevision:
            return WorkshopProtocol.ErrorCode.staleRevision
        case .illegalTransition, .adapterUnavailable:
            return WorkshopProtocol.ErrorCode.internalError
        }
    }

    public var message: String {
        switch self {
        case .idempotencyConflict:
            return "Idempotency key was already used with a different payload"
        case .invalidRequest(let why):
            return "Invalid request: \(why)"
        case .methodNotFound(let method):
            return "Method not found: \(method)"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .illegalTransition(let from, let to):
            return "Illegal task transition \(from.rawValue) -> \(to.rawValue)"
        case .adapterUnavailable(let id):
            return "Adapter unavailable: \(id.rawValue)"
        case .notAParticipant(let engineer, let task):
            return "Engineer \(engineer.rawValue) is not a participant of task \(task.rawValue)"
        case .notOwner:
            return "Caller is not the current owner of the subtask"
        case .workspaceEscape(let path):
            return "Path escapes the task workspace: \(path)"
        case .phaseNotImplemented(let tool):
            return "\(tool) arrives in Phase 3/5; not implemented"
        case .userAuthorityRequired(let what):
            return "User authority required: \(what)"
        case .approvalRequired(let task):
            return "Task \(task.rawValue) requires an approved current report revision before implementation"
        case .blockedByDependency(let sub):
            return "Subtask \(sub.rawValue) has unfinished dependencies"
        case .staleRevision(let expected, let actual):
            return "Stale report revision \(expected); current is \(actual.map(String.init) ?? "none")"
        }
    }
}
