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
    /// Latest consolidated report revision (research path, Phase 3).
    public var reportRevision: Int?
    /// Set when cancellation was requested while a turn was running.
    public var cancelRequestedAt: Date?
    public var budgetPolicyRef: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// §5.1 classification for display: explicit phase is the classifier.
    public var classification: String {
        phase == .researchProposal ? "substantial" : "small"
    }

    /// Whether the current report revision is covered by an active approval.
    public var hasCurrentApproval: Bool {
        approvalRevision != nil && approvalRevision == reportRevision
    }

    public init(id: TaskID, channel: String, title: String, brief: String, phase: TaskPhase,
                state: TaskState, scopeRevision: Int = 1, approvalRevision: Int? = nil,
                reportRevision: Int? = nil, cancelRequestedAt: Date? = nil,
                budgetPolicyRef: String? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.channel = channel
        self.title = title
        self.brief = brief
        self.phase = phase
        self.state = state
        self.scopeRevision = scopeRevision
        self.approvalRevision = approvalRevision
        self.reportRevision = reportRevision
        self.cancelRequestedAt = cancelRequestedAt
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
    /// Optional JSON card payload (structured results, review requests).
    public var structured: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: MessageID, taskID: TaskID, seq: Int64, author: Principal, kind: MessageKind,
                body: String, replyTo: MessageID? = nil, correlationID: String? = nil,
                revision: Int = 1, deliveryState: DeliveryState = .committed,
                structured: String? = nil, createdAt: Date, updatedAt: Date) {
        self.structured = structured
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
    /// Highest message seq consumed by a completed turn (§8.5).
    public var lastReadSeq: Int64
    public var subscriptions: [String]

    public init(taskID: TaskID, engineerID: EngineerID, membership: String = "member",
                readCursor: Int64 = 0, lastReadSeq: Int64 = 0, subscriptions: [String] = []) {
        self.taskID = taskID
        self.engineerID = engineerID
        self.membership = membership
        self.readCursor = readCursor
        self.lastReadSeq = lastReadSeq
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
    /// Risk tier from the report/proposal (normal|high).
    public var risk: String
    /// Verification outcome (none|passed|changes_requested).
    public var verification: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: SubtaskID, taskID: TaskID, title: String, acceptance: [String] = [],
                dependencies: [String] = [], ownerID: EngineerID? = nil, generation: Int = 0,
                leaseExpiresAt: Date? = nil, state: SubtaskState = .ready,
                risk: String = "normal", verification: String = "none",
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
        self.risk = risk
        self.verification = verification
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

/// One wakeup row for status display (queued/running/suppressed/done).
public struct WakeupInfo: Codable, Equatable, Sendable {
    public var engineer: EngineerID
    public var reason: String
    public var state: String

    public init(engineer: EngineerID, reason: String, state: String) {
        self.engineer = engineer
        self.reason = reason
        self.state = state
    }
}

/// Task detail returned by getTask.
public struct TaskDetail: Codable, Equatable, Sendable {
    public var task: WorkshopTask
    public var participants: [Participant]
    public var subtasks: [Subtask]
    /// Latest recorded usage sample for the task, if any.
    public var usage: UsageSample?
    /// Engineers with a turn currently running on this task.
    public var runningEngineers: [EngineerID]
    /// Pending/running wakeup rows for this task (status chips).
    public var pendingWakeups: [WakeupInfo]
    /// Proposal visibility counts (T12: drafts are private; only counts show).
    public var draftProposalCount: Int
    public var publishedProposalCount: Int
    public var ingress: TaskIngress?
    public var workspace: TaskWorkspace?

    public init(task: WorkshopTask, participants: [Participant], subtasks: [Subtask],
                usage: UsageSample? = nil, runningEngineers: [EngineerID] = [],
                pendingWakeups: [WakeupInfo] = [], draftProposalCount: Int = 0,
                publishedProposalCount: Int = 0, ingress: TaskIngress? = nil,
                workspace: TaskWorkspace? = nil) {
        self.task = task
        self.participants = participants
        self.subtasks = subtasks
        self.usage = usage
        self.runningEngineers = runningEngineers
        self.pendingWakeups = pendingWakeups
        self.draftProposalCount = draftProposalCount
        self.publishedProposalCount = publishedProposalCount
        self.ingress = ingress
        self.workspace = workspace
    }
}

/// A persisted usage_samples row (listUsage).
public struct UsageSampleRecord: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var engineerID: EngineerID
    public var provider: String
    public var model: String?
    public var nativeSessionID: String?
    public var turnID: String?
    public var sample: UsageSample
    public var observedAt: Date

    public init(taskID: TaskID, engineerID: EngineerID, provider: String,
                model: String? = nil, nativeSessionID: String? = nil,
                turnID: String? = nil, sample: UsageSample, observedAt: Date) {
        self.taskID = taskID
        self.engineerID = engineerID
        self.provider = provider
        self.model = model
        self.nativeSessionID = nativeSessionID
        self.turnID = turnID
        self.sample = sample
        self.observedAt = observedAt
    }
}

/// A registered artifact with content-hash provenance (spec §8.1).
public struct Artifact: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var contentHash: String
    public var relativePath: String
    public var mime: String?
    public var producer: String
    public var baseRevision: String?
    public var validation: String
    public var description: String?
    /// Ownership generation the artifact was produced under (fencing, T05).
    public var generation: Int?
    public var createdAt: Date

    public init(id: String, taskID: TaskID, contentHash: String, relativePath: String,
                mime: String? = nil, producer: String, baseRevision: String? = nil,
                validation: String = "unverified", description: String? = nil,
                generation: Int? = nil, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.contentHash = contentHash
        self.relativePath = relativePath
        self.mime = mime
        self.producer = producer
        self.baseRevision = baseRevision
        self.validation = validation
        self.description = description
        self.generation = generation
        self.createdAt = createdAt
    }
}

/// A research-phase proposal (Phase 3). Drafts are private to the author.
public struct Proposal: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var author: EngineerID
    public var revision: Int
    /// draft | published
    public var visibility: String
    /// JSON content (title, summary, approach, alternatives, …).
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, taskID: TaskID, author: EngineerID, revision: Int = 1,
                visibility: String = "draft", content: String,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.taskID = taskID
        self.author = author
        self.revision = revision
        self.visibility = visibility
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A consolidated report revision (Phase 3, §5.3).
public struct Report: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var revision: Int
    public var author: String
    /// JSON content (recommendation, alternatives, proposed_ownership, …).
    public var content: String
    public var createdAt: Date

    public init(id: String, taskID: TaskID, revision: Int, author: String,
                content: String, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.revision = revision
        self.author = author
        self.content = content
        self.createdAt = createdAt
    }
}

/// A recorded decision (Phase 3): approvals, allocations, disputes, …
public struct Decision: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: TaskID
    /// approval|request_changes|choose_alternative|allocation|dispute|
    /// escalation|acceptance|scope_change|cancellation
    public var kind: String
    public var revision: Int?
    public var scope: String?
    public var author: String
    public var body: String
    public var relatedID: String?
    public var createdAt: Date

    public init(id: String, taskID: TaskID, kind: String, revision: Int? = nil,
                scope: String? = nil, author: String, body: String,
                relatedID: String? = nil, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.revision = revision
        self.scope = scope
        self.author = author
        self.body = body
        self.relatedID = relatedID
        self.createdAt = createdAt
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

// MARK: - Phase 4 models

/// A capacity observation for an engineer's budget bucket (§10).
public struct QuotaSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var bucket: String
    /// Remaining as a decimal string, or "unknown" — never a guess.
    public var remaining: String
    public var unit: String?
    public var resetAt: Date?
    public var source: String
    public var observedAt: Date
    /// available | low | critical | limited | unknown
    public var availability: String

    public init(id: Int64 = 0, bucket: String, remaining: String,
                unit: String? = nil, resetAt: Date? = nil, source: String,
                observedAt: Date, availability: String) {
        self.id = id
        self.bucket = bucket
        self.remaining = remaining
        self.unit = unit
        self.resetAt = resetAt
        self.source = source
        self.observedAt = observedAt
        self.availability = availability
    }
}

/// A pre-dispatch capacity reservation, reconciled to actual usage after the
/// turn (§10, T13/T14).
public struct Reservation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var engineerID: EngineerID
    public var bucket: String
    public var reserved: Int
    public var committed: Int?
    /// held | reconciled | released
    public var state: String
    public var expiresAt: Date
    public var createdAt: Date

    public init(id: String, taskID: TaskID, engineerID: EngineerID,
                bucket: String, reserved: Int, committed: Int? = nil,
                state: String = "held", expiresAt: Date, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.engineerID = engineerID
        self.bucket = bucket
        self.reserved = reserved
        self.committed = committed
        self.state = state
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// A named resource lease (browser/computer-use registry, §9.2, T24).
/// Workshop exposes no browser tool itself; this registry coordinates
/// whichever engineer's runtime has one (ADR 0014).
public struct ResourceLease: Codable, Equatable, Sendable {
    public var resource: String
    public var owner: String
    public var taskID: TaskID?
    public var generation: Int
    public var expiresAt: Date
    public var url: String?
    public var updatedAt: Date

    public init(resource: String, owner: String, taskID: TaskID? = nil,
                generation: Int = 1, expiresAt: Date, url: String? = nil,
                updatedAt: Date) {
        self.resource = resource
        self.owner = owner
        self.taskID = taskID
        self.generation = generation
        self.expiresAt = expiresAt
        self.url = url
        self.updatedAt = updatedAt
    }

    public func expired(at now: Date) -> Bool { expiresAt <= now }
}

/// One adapter turn (T05/T23/T29). Timing columns feed §14.5 latency layers.
public struct Turn: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var subtaskID: SubtaskID?
    public var engineerID: EngineerID
    public var generation: Int?
    /// running | completed | failed | cancel_requested | cancelled |
    /// interrupted | uncertain
    public var state: String
    public var startedAt: Date
    public var firstEventAt: Date?
    public var endedAt: Date?
    public var nativeSessionID: String?
    public var requestIDs: [String]

    public init(id: String, taskID: TaskID, subtaskID: SubtaskID? = nil,
                engineerID: EngineerID, generation: Int? = nil,
                state: String = "running", startedAt: Date,
                firstEventAt: Date? = nil, endedAt: Date? = nil,
                nativeSessionID: String? = nil, requestIDs: [String] = []) {
        self.id = id
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.engineerID = engineerID
        self.generation = generation
        self.state = state
        self.startedAt = startedAt
        self.firstEventAt = firstEventAt
        self.endedAt = endedAt
        self.nativeSessionID = nativeSessionID
        self.requestIDs = requestIDs
    }
}
