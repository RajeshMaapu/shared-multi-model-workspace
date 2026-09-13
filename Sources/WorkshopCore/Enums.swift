import Foundation

/// Work phase of a task (spec §8.4).
public enum TaskPhase: String, Codable, CaseIterable, Sendable {
    case researchProposal = "research_proposal"
    case execution = "execution"
    case followUp = "follow_up"

    public var displayName: String {
        switch self {
        case .researchProposal: return "Research"
        case .execution: return "Execution"
        case .followUp: return "Follow-up"
        }
    }
}

/// Task state machine (spec §8.2).
public enum TaskState: String, Codable, CaseIterable, Sendable {
    case draft
    case queued
    case researching
    case reviewingProposal = "reviewing_proposal"
    case awaitingArchitectureApproval = "awaiting_architecture_approval"
    case ready
    case working
    case verifying
    case done
    case blocked
    case paused
    case cancelled

    /// Edges of the §8.2 state diagram.
    public func canTransition(to next: TaskState) -> Bool {
        switch (self, next) {
        case (.draft, .queued): return true
        case (.queued, .researching), (.queued, .ready): return true
        case (.researching, .reviewingProposal): return true
        case (.reviewingProposal, .awaitingArchitectureApproval): return true
        case (.awaitingArchitectureApproval, .ready): return true
        case (.ready, .working), (.ready, .cancelled): return true
        case (.working, .verifying), (.working, .blocked),
             (.working, .paused), (.working, .cancelled): return true
        case (.verifying, .done), (.verifying, .working): return true
        case (.blocked, .ready): return true
        case (.paused, .ready): return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .queued: return "Queued"
        case .researching: return "Researching"
        case .reviewingProposal: return "Reviewing proposal"
        case .awaitingArchitectureApproval: return "Awaiting approval"
        case .ready: return "Ready"
        case .working: return "Working"
        case .verifying: return "Verifying"
        case .done: return "Done"
        case .blocked: return "Blocked"
        case .paused: return "Paused"
        case .cancelled: return "Cancelled"
        }
    }
}

public enum MessageKind: String, Codable, CaseIterable, Sendable {
    case text
    case proposal
    case assignment
    case review
    case artifact
    case decision
    case systemEvent = "system_event"
}

/// Author of a message or operation.
public enum Principal: Codable, Hashable, Sendable {
    case user
    case engineer(EngineerID)
    case system

    public var kind: String {
        switch self {
        case .user: return "user"
        case .engineer: return "engineer"
        case .system: return "system"
        }
    }

    /// Engineer id when the principal is an engineer, else nil.
    public var engineerID: EngineerID? {
        if case .engineer(let id) = self { return id }
        return nil
    }

    public var displayName: String {
        switch self {
        case .user: return "You"
        case .engineer(let id): return id.displayName
        case .system: return "Workshop"
        }
    }

    public init(kind: String, engineerID: String?) {
        switch kind {
        case "engineer": self = .engineer(EngineerID(rawValue: engineerID ?? "") ?? .devin)
        case "system": self = .system
        default: self = .user
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        if s.hasPrefix("engineer:") {
            self = .engineer(EngineerID(rawValue: String(s.dropFirst(9))) ?? .devin)
        } else {
            self = s == "system" ? .system : .user
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .user: try c.encode("user")
        case .system: try c.encode("system")
        case .engineer(let id): try c.encode("engineer:" + id.rawValue)
        }
    }
}

public enum DeliveryState: String, Codable, Sendable {
    case streaming
    case committed
}

/// Health of an engineer adapter, with a human-readable detail string.
public struct EngineerHealth: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case available
        case loginRequired = "login_required"
        case incompatibleVersion = "incompatible_version"
        case quotaLimited = "quota_limited"
        case unavailable
    }

    public var kind: Kind
    public var detail: String

    public init(_ kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public static func available(_ detail: String = "Available") -> EngineerHealth { .init(.available, detail: detail) }
    public static func loginRequired(_ detail: String = "Login required") -> EngineerHealth { .init(.loginRequired, detail: detail) }
    public static func incompatibleVersion(_ detail: String) -> EngineerHealth { .init(.incompatibleVersion, detail: detail) }
    public static func quotaLimited(_ detail: String) -> EngineerHealth { .init(.quotaLimited, detail: detail) }
    public static func unavailable(_ detail: String = "Unavailable") -> EngineerHealth { .init(.unavailable, detail: detail) }

    public var label: String {
        switch kind {
        case .available: return "Available"
        case .loginRequired: return "Login required"
        case .incompatibleVersion: return "Incompatible version"
        case .quotaLimited: return "Quota limited"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Result of an adapter health/capability probe (spec §7.1).
public struct AdapterProbe: Codable, Equatable, Sendable {
    public var engineer: EngineerID
    public var health: EngineerHealth
    public var versions: [String: String]
    public var effectiveModel: String?
    public var capabilities: Set<String>

    public init(engineer: EngineerID, health: EngineerHealth, versions: [String: String] = [:],
                effectiveModel: String? = nil, capabilities: Set<String> = []) {
        self.engineer = engineer
        self.health = health
        self.versions = versions
        self.effectiveModel = effectiveModel
        self.capabilities = capabilities
    }
}
