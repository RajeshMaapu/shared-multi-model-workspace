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
        }
    }
}
