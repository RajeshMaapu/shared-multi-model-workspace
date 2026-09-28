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
    /// Review targeted a superseded result message (-32008).
    case staleResult(latestMessageID: String, latestRevision: Int)
    /// Stale ownership generation fenced at the tool boundary (-32004, T05).
    case staleGeneration(engineer: EngineerID, supplied: Int, current: Int)
    /// Free disk below the storage-guard threshold (-32010, T30).
    case storageLow(freeBytes: Int64)
    /// Too many concurrent wait_for_events waiters for this principal kind.
    case tooManyWaiters

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
        case .notOwner, .staleGeneration:
            return WorkshopProtocol.ErrorCode.notOwner
        case .storageLow:
            return WorkshopProtocol.ErrorCode.storageLow
        case .tooManyWaiters:
            return WorkshopProtocol.ErrorCode.tooManyWaiters
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
        case .staleRevision, .staleResult:
            return WorkshopProtocol.ErrorCode.staleRevision
        case .illegalTransition, .adapterUnavailable:
            return WorkshopProtocol.ErrorCode.internalError
        }
    }

    public var message: String {
        switch self {
        case .idempotencyConflict:
            return "idempotency conflict: key was already used with a different payload"
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
        case .staleResult(let latestMessageID, let latestRevision):
            return "result superseded; review the latest result \(latestMessageID) (revision \(latestRevision))"
        case .staleGeneration(let engineer, let supplied, let current):
            return "Stale ownership generation \(supplied) from \(engineer.rawValue); current is \(current)"
        case .storageLow(let freeBytes):
            return "Storage critically low (\(freeBytes / 1_048_576) MiB free); write refused"
        case .tooManyWaiters:
            return "Too many concurrent wait_for_events waiters"
        }
    }
}

extension WorkshopError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Render an error for user-facing surfaces (system events, logs) without
/// losing the underlying cause. `localizedDescription` alone collapses typed
/// errors to "The operation couldn't be completed"; this keeps provider and
/// harness detail (e.g. a team-settings timeout) visible.
public func workshopErrorDescription(_ error: Error) -> String {
    if let rpc = error as? WorkshopRPCError { return rpc.message }
    if let localized = error as? LocalizedError,
       let detail = localized.errorDescription { return detail }
    if error is CancellationError { return "cancelled" }
    return String(describing: error)
}

/// Coarse classification of a turn-startup failure (G-D2): decides whether a
/// retry can help (timeout/transport) or must stop (auth) and what remedy to
/// surface on the engineer card.
public enum StartupFailureClass: String, Sendable {
    case auth, timeout, transport, sandbox, `internal`, unknown

    public static func classify(_ description: String) -> StartupFailureClass {
        let d = description.lowercased()
        if ["authentication required", "-32000", "oauthunauthorized",
            "authorization grant", "login required"].contains(where: d.contains) {
            return .auth
        }
        if ["timed out", "timeout", "no response after"].contains(where: d.contains) {
            return .timeout
        }
        if ["broken pipe", "filehandle", "connection closed", "eof",
            "cancelled"].contains(where: d.contains) {
            return .transport
        }
        if ["eperm", "operation not permitted", "sandbox"].contains(where: d.contains) {
            return .sandbox
        }
        if ["-32603", "internal error"].contains(where: d.contains) {
            return .internal
        }
        return .unknown
    }

    /// User-facing remedy for an auth-class failure, per engineer.
    public static func loginRemedy(for engineer: EngineerID) -> String {
        switch engineer {
        case .devin:
            return "run `devin` once in a terminal to refresh credentials"
        case .kimi:
            return "run `kimi acp --login` (or `kimi --login`) in a terminal"
        case .deepseek:
            return "check the DeepSeek API key reference in the Kimi config"
        }
    }
}
