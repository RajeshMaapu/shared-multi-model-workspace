import Foundation
import CryptoKit

public enum CollaborationMode: String, Codable, Sendable {
    case ownerOnly = "owner_only"
    case requestedPeers = "requested_peers"
}

public struct TaskOrigin: Codable, Equatable, Sendable {
    public var sourceTaskID: String
    public var invocationID: String
    enum CodingKeys: String, CodingKey {
        case sourceTaskID = "source_task_id"
        case invocationID = "invocation_id"
    }
    public init(sourceTaskID: String, invocationID: String) {
        self.sourceTaskID = sourceTaskID
        self.invocationID = invocationID
    }
}

public struct TaskIngress: Codable, Equatable, Sendable {
    public var request: CreateTaskRequest
    public var source: String
    public var lastAcknowledgedSeq: Int64

    public init(request: CreateTaskRequest, source: String, lastAcknowledgedSeq: Int64 = 0) {
        self.request = request
        self.source = source
        self.lastAcknowledgedSeq = lastAcknowledgedSeq
    }
}

/// Create-task contract (spec §8.4). `channel` defaults to "projects".
public struct CreateTaskRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var idempotencyKey: String
    public var title: String
    public var objective: String
    public var phase: TaskPhase
    public var participants: [EngineerID]
    public var constraints: [String]
    public var sources: [String]
    public var workspaceRef: String?
    public var acceptanceCriteria: [String]
    public var budgetPolicyRef: String?
    public var channel: String
    public var collaborationMode: CollaborationMode?
    public var origin: TaskOrigin?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case idempotencyKey = "idempotency_key"
        case title, objective, phase, participants, constraints, sources
        case workspaceRef = "workspace_ref"
        case acceptanceCriteria = "acceptance_criteria"
        case budgetPolicyRef = "budget_policy_ref"
        case channel
        case collaborationMode = "collaboration_mode"
        case origin
    }

    public init(schemaVersion: Int = 1, idempotencyKey: String, title: String, objective: String,
                phase: TaskPhase, participants: [EngineerID], constraints: [String] = [],
                sources: [String] = [], workspaceRef: String? = nil,
                acceptanceCriteria: [String] = [], budgetPolicyRef: String? = nil,
                channel: String = "projects",
                collaborationMode: CollaborationMode? = nil,
                origin: TaskOrigin? = nil) {
        self.schemaVersion = schemaVersion
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.objective = objective
        self.phase = phase
        self.participants = participants
        self.constraints = constraints
        self.sources = sources
        self.workspaceRef = workspaceRef
        self.acceptanceCriteria = acceptanceCriteria
        self.budgetPolicyRef = budgetPolicyRef
        self.channel = channel
        self.collaborationMode = collaborationMode
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        idempotencyKey = try c.decode(String.self, forKey: .idempotencyKey)
        title = try c.decode(String.self, forKey: .title)
        objective = try c.decode(String.self, forKey: .objective)
        phase = try c.decode(TaskPhase.self, forKey: .phase)
        participants = try c.decodeIfPresent([EngineerID].self, forKey: .participants) ?? []
        constraints = try c.decodeIfPresent([String].self, forKey: .constraints) ?? []
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        workspaceRef = try c.decodeIfPresent(String.self, forKey: .workspaceRef)
        acceptanceCriteria = try c.decodeIfPresent([String].self, forKey: .acceptanceCriteria) ?? []
        budgetPolicyRef = try c.decodeIfPresent(String.self, forKey: .budgetPolicyRef)
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? "projects"
        collaborationMode = try c.decodeIfPresent(CollaborationMode.self, forKey: .collaborationMode)
        origin = try c.decodeIfPresent(TaskOrigin.self, forKey: .origin)
    }
}

public enum CreateTaskStatus: String, Codable, Sendable {
    case created
    case queued
    case running
}

/// Truthful receipt (spec §8.4). `deepLink` stays nil until the URL scheme is registered.
public struct CreateTaskReceipt: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var committedSeq: Int64
    public var state: TaskState
    public var status: CreateTaskStatus
    public var deepLink: String?

    public init(taskID: TaskID, committedSeq: Int64, state: TaskState,
                status: CreateTaskStatus, deepLink: String? = nil) {
        self.taskID = taskID
        self.committedSeq = committedSeq
        self.state = state
        self.status = status
        self.deepLink = deepLink
    }
}

/// Sorted-key JSON, SHA-256 hex. Used to detect changed payloads under the same idempotency key.
public func canonicalJSONHash<T: Encodable>(of value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
