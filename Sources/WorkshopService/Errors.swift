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
        }
    }
}
