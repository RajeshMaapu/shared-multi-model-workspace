import Foundation

public struct WorkshopTask: Codable, Equatable, Sendable {
    public var id: TaskID
    public var channel: String
    public var title: String
    public var brief: String
    public var phase: TaskPhase
    public var state: TaskState
    public var scopeRevision: Int
    public var approvalRevision: Int?
    public var budgetPolicyRef: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: TaskID, channel: String, title: String, brief: String, phase: TaskPhase,
                state: TaskState, scopeRevision: Int = 1, approvalRevision: Int? = nil,
                budgetPolicyRef: String? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.channel = channel
        self.title = title
        self.brief = brief
        self.phase = phase
        self.state = state
        self.scopeRevision = scopeRevision
        self.approvalRevision = approvalRevision
        self.budgetPolicyRef = budgetPolicyRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public var id: MessageID
    public var taskID: TaskID
    public var seq: Int64
    public var author: Principal
    public var kind: MessageKind
    public var body: String
    public var replyTo: MessageID?
    public var correlationID: String?
    public var revision: Int
    public var deliveryState: DeliveryState
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: MessageID, taskID: TaskID, seq: Int64, author: Principal, kind: MessageKind,
                body: String, replyTo: MessageID? = nil, correlationID: String? = nil,
                revision: Int = 1, deliveryState: DeliveryState = .committed,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.taskID = taskID
        self.seq = seq
        self.author = author
        self.kind = kind
        self.body = body
        self.replyTo = replyTo
        self.correlationID = correlationID
        self.revision = revision
        self.deliveryState = deliveryState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Participant: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var engineerID: EngineerID
    public var membership: String
    public var readCursor: Int64
    public var subscriptions: [String]

    public init(taskID: TaskID, engineerID: EngineerID, membership: String = "member",
                readCursor: Int64 = 0, subscriptions: [String] = []) {
        self.taskID = taskID
        self.engineerID = engineerID
        self.membership = membership
        self.readCursor = readCursor
        self.subscriptions = subscriptions
    }
}

public enum SubtaskState: String, Codable, CaseIterable, Sendable {
    case ready
    case claimed
    case working
    case review
    case blocked
    case done

    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

public struct Subtask: Codable, Equatable, Sendable, Identifiable {
    public var id: SubtaskID
    public var taskID: TaskID
    public var title: String
    public var acceptance: [String]
    public var dependencies: [String]
    public var ownerID: EngineerID?
    public var generation: Int
    public var leaseExpiresAt: Date?
    public var state: SubtaskState
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: SubtaskID, taskID: TaskID, title: String, acceptance: [String] = [],
                dependencies: [String] = [], ownerID: EngineerID? = nil, generation: Int = 0,
                leaseExpiresAt: Date? = nil, state: SubtaskState = .ready,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.acceptance = acceptance
        self.dependencies = dependencies
        self.ownerID = ownerID
        self.generation = generation
        self.leaseExpiresAt = leaseExpiresAt
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Measured usage counters. Missing telemetry stays null, never zero (§6.4/§10.1).
public struct UsageSample: Codable, Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var source: String

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case source
    }

    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil,
                cacheWrite: Int? = nil, source: String) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input)
        output = try c.decodeIfPresent(Int.self, forKey: .output)
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead)
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
    }

    // Encoded explicitly so missing telemetry stays JSON null, never absent or zero.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let input { try c.encode(input, forKey: .input) } else { try c.encodeNil(forKey: .input) }
        if let output { try c.encode(output, forKey: .output) } else { try c.encodeNil(forKey: .output) }
        if let cacheRead { try c.encode(cacheRead, forKey: .cacheRead) } else { try c.encodeNil(forKey: .cacheRead) }
        if let cacheWrite { try c.encode(cacheWrite, forKey: .cacheWrite) } else { try c.encodeNil(forKey: .cacheWrite) }
        try c.encode(source, forKey: .source)
    }
}

/// Task detail returned by getTask.
public struct TaskDetail: Codable, Equatable, Sendable {
    public var task: WorkshopTask
    public var participants: [Participant]
    public var subtasks: [Subtask]
    /// Latest recorded usage sample for the task, if any.
    public var usage: UsageSample?

    public init(task: WorkshopTask, participants: [Participant], subtasks: [Subtask],
                usage: UsageSample? = nil) {
        self.task = task
        self.participants = participants
        self.subtasks = subtasks
        self.usage = usage
    }
}

/// A committed fact awaiting delivery to subscribers (spec §8.5).
public struct OutboxEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64 { seq }
    public var seq: Int64
    public var taskID: TaskID?
    public var eventType: String
    public var recipients: [String]
    public var payload: String
    public var deliveryState: String
    public var createdAt: Date
    public var deliveredAt: Date?

    public init(seq: Int64, taskID: TaskID?, eventType: String, recipients: [String] = [],
                payload: String, deliveryState: String, createdAt: Date, deliveredAt: Date? = nil) {
        self.seq = seq
        self.taskID = taskID
        self.eventType = eventType
        self.recipients = recipients
        self.payload = payload
        self.deliveryState = deliveryState
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
    }
}
