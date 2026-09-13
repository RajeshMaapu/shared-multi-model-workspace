import CryptoKit
import Foundation
import os
import SQLite3
#if canImport(AppKit)
import AppKit
#endif
import WorkshopCore
import WorkshopStore

/// Single-writer collaboration service: owns the database, adapter registry,
/// outbox dispatch and recovery (spec §4.3, §5.2, §9.4).
public actor CollaborationService {
    public static let dispatchRequested = "dispatch.requested"

    private let repo: WorkshopRepository
    private var adapters: [EngineerID: EngineerAdapter]
    private let now: () -> Date
    private let dispatcherEnabled: Bool
    private var dispatcherScheduled = false
    private var inflightTurns = 0
    private var eventContinuations: [UUID: AsyncStream<OutboxEvent>.Continuation] = [:]
    private var lastPublishedSeq: Int64 = 0
    private var isShutdown = false

    /// Workshop home dir (tokens, artifacts, worktrees); nil in bare tests.
    public let homeDir: String?
    /// Wakeup batching interval (§5.4); 0 in tests.
    private let wakeupCoalescence: Duration
    /// Max consecutive engineer-triggered wakeups without a user message (T11).
    private let wakeupLoopBound: Int
    private var wakeupScheduled = false
    /// (task, engineer) pairs with a turn currently running.
    private var runningTurns: Set<String> = []
    /// Turn handles for pause/cancel: "<task>:<engineer>" → adapter+ref+turnID.
    private var runningTurnRefs:
        [String: (adapter: EngineerAdapter, ref: SessionRef, turnID: String)] = [:]
    /// Phase 4: per-engineer capacity policy (nil → no measurement → unknown).
    private let capacityPolicies: [EngineerID: CapacityPolicy]
    private let requireKnownCapacity: Bool
    /// Injectable free-space probe for the storage guard (T30); nil → statfs.
    private let freeSpaceBytes: (@Sendable () -> Int64)?
    /// Engineers whose next turn must end with a save_checkpoint request.
    private var checkpointRequested: Set<EngineerID> = []
    /// Last adapter probe per engineer (T15 re-probe throttle, §10).
    private var lastProbeAt: [EngineerID: Date] = [:]
    private var lastProbes: [EngineerID: AdapterProbe] = [:]
    /// Buckets already reported blocked (one systemEvent per bucket/task).
    private var capacityBlockedNotified: Set<String> = []
    /// Tasks already notified about low disk (one event per task).
    private var lowDiskNotified: Set<TaskID> = []
    /// Whether the host is asleep (willSleepNotification → reconcile skip).
    private var sleeping = false
    /// Sleeper state observers installed by installSleepWakeHooks.
    private var sleepObservers: [NSObjectProtocol] = []
    /// TurnID → durable turn row id for running turns (heartbeat/heartbeat-end).
    private var runningTurnRowIDs: [String: String] = [:]
    /// External balance probe (DeepSeek /user/balance); set by the daemon.
    private var balanceProbe: (@Sendable (EngineerID) async -> QuotaSnapshot?)?

    public func setBalanceProbe(
        _ probe: @escaping @Sendable (EngineerID) async -> QuotaSnapshot?) {
        balanceProbe = probe
    }
    private var lastBalanceRefresh: Date?
    /// Wake-reconcile process liveness probes registered by the daemon.
    private var harnessAliveProbes: [EngineerID: @Sendable () -> Bool] = [:]
    /// Checkpoint JSON carried into the next resume_from_checkpoint packet.
    private var pendingCheckpointDetail: [EngineerID: String] = [:]
    private var lastWalCheckpoint: Date?
    /// Research-phase deadlines in seconds; <= 0 disables the timer (tests).
    private let researchDeadline: TimeInterval
    private let reviewDeadline: TimeInterval
    /// Scheduled policy deadline timers keyed "research:<task>" / "review:<task>".
    private var policyTimers: [String: Task<Void, Never>] = [:]

    /// Test hook: called with the rendered context packet before each sendTurn.
    public var packetInspector: (@Sendable (EngineerID, String) -> Void)?

    public func setPacketInspector(_ f: (@Sendable (EngineerID, String) -> Void)?) {
        packetInspector = f
    }

    private let log = Logger(subsystem: "ai.maapu.workshop", category: "service")

    /// Run a repo/db mutation, logging failures instead of silently swallowing them.
    private func attempt<T>(_ label: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            log.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public init(database: Database, adapters: [EngineerAdapter],
                dispatcherEnabled: Bool = true,
                homeDir: String? = nil,
                wakeupCoalescence: Duration = .milliseconds(500),
                wakeupLoopBound: Int = 6,
                researchDeadline: TimeInterval = 1200,
                reviewDeadline: TimeInterval = 900,
                capacityPolicies: [EngineerID: CapacityPolicy] = [:],
                requireKnownCapacity: Bool = false,
                freeSpaceBytes: (@Sendable () -> Int64)? = nil,
                now: @escaping () -> Date = Date.init) throws {
        try Migrations.all.migrate(database)
        self.repo = WorkshopRepository(db: database)
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.engineer, $0) })
        self.dispatcherEnabled = dispatcherEnabled
        self.homeDir = homeDir
        self.wakeupCoalescence = wakeupCoalescence
        self.wakeupLoopBound = wakeupLoopBound
        self.researchDeadline = researchDeadline
        self.reviewDeadline = reviewDeadline
        self.capacityPolicies = capacityPolicies
        self.requireKnownCapacity = requireKnownCapacity
        self.freeSpaceBytes = freeSpaceBytes
        self.now = now
    }

    public convenience init(databasePath: String, adapters: [EngineerAdapter],
                            dispatcherEnabled: Bool = true,
                            homeDir: String? = nil,
                            wakeupCoalescence: Duration = .milliseconds(500),
                            wakeupLoopBound: Int = 6,
                            researchDeadline: TimeInterval = 1200,
                            reviewDeadline: TimeInterval = 900,
                            capacityPolicies: [EngineerID: CapacityPolicy] = [:],
                            requireKnownCapacity: Bool = false,
                            freeSpaceBytes: (@Sendable () -> Int64)? = nil,
                            now: @escaping () -> Date = Date.init) throws {
        try self.init(database: try Database(path: databasePath), adapters: adapters,
                      dispatcherEnabled: dispatcherEnabled, homeDir: homeDir,
                      wakeupCoalescence: wakeupCoalescence,
                      wakeupLoopBound: wakeupLoopBound,
                      researchDeadline: researchDeadline,
                      reviewDeadline: reviewDeadline,
                      capacityPolicies: capacityPolicies,
                      requireKnownCapacity: requireKnownCapacity,
                      freeSpaceBytes: freeSpaceBytes, now: now)
    }

    // MARK: - Authentication

    /// Resolve a capability token to an engineer principal (spec §9.3). Tokens are
    /// 32-byte hex files at <home>/profiles/<engineer>/token generated by the daemon.
    public func authenticate(token: String) throws -> Principal {
        guard let homeDir else { throw WorkshopError.invalidRequest("no token store") }
        for engineer in EngineerID.allCases {
            let path = homeDir + "/profiles/" + engineer.rawValue + "/token"
            guard let stored = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !stored.isEmpty, stored == token else { continue }
            return .engineer(engineer)
        }
        // Codex principal: profiles/codex/token → limited authority (§9.3).
        let codexPath = homeDir + "/profiles/codex/token"
        if let stored = try? String(contentsOfFile: codexPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty, stored == token {
            return .codex
        }
        throw WorkshopError.invalidRequest("invalid token")
    }

    /// Recovery, then process any pending dispatch rows exactly once (T03).
    public func start() async {
        reconcileOnStart()
        recoverInterruptedStreams()
        scheduleDispatch()
        scheduleLeaseSweeper()
        scheduleWalMonitor()
    }

    /// Replace an adapter after init (e.g. binding a live adapter's tool
    /// executor to this service). Used at daemon startup.
    public func registerAdapter(_ adapter: EngineerAdapter) {
        adapters[adapter.engineer] = adapter
    }

    public func shutdown() {
        isShutdown = true
        for timer in policyTimers.values { timer.cancel() }
        policyTimers.removeAll()
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    /// Wait until the dispatcher has no pending work. For tests.
    public func awaitIdle() async {
        while dispatcherScheduled || inflightTurns > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if let pending = attempt("pendingOutbox", { try repo.pendingOutbox(eventType: Self.dispatchRequested) }),
           !pending.isEmpty, dispatcherEnabled, !isShutdown {
            scheduleDispatch()
            while dispatcherScheduled || inflightTurns > 0 {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    // MARK: - Event broadcast

    /// In-process stream of committed outbox events (plus transient message.delta events).
    public func makeEventStream() -> AsyncStream<OutboxEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func publishCommitted() {
        guard let rows = attempt("outboxEvents", { try repo.outboxEvents(afterSeq: lastPublishedSeq) }) else { return }
        let timestamp = now()
        for row in rows {
            lastPublishedSeq = max(lastPublishedSeq, row.seq)
            for continuation in eventContinuations.values {
                continuation.yield(row)
            }
            // §8.5: once yielded to in-process subscribers the row is
            // delivered and the service cursor advances — nothing stays
            // pending forever. dispatch.requested rows are owned by the
            // dispatcher, which marks them delivered/failed itself.
            if row.deliveryState == "pending", row.eventType != Self.dispatchRequested {
                _ = attempt("markOutboxDelivered") {
                    try repo.markOutboxDelivered(row.seq, at: timestamp)
                }
            }
            _ = attempt("outboxCursor") {
                try repo.setOutboxCursor("service", seq: row.seq, at: timestamp)
            }
        }
    }

    private func publishTransient(taskID: TaskID, type: String, payload: String) {
        let event = OutboxEvent(seq: lastPublishedSeq, taskID: taskID, eventType: type,
                                payload: payload, deliveryState: "transient",
                                createdAt: now())
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Queries

    public func listTasks() throws -> [WorkshopTask] {
        try repo.listTasks()
    }

    public func getTask(_ id: TaskID) throws -> TaskDetail {
        guard let task = try repo.task(id) else { throw WorkshopError.taskNotFound(id) }
        var usage = try repo.latestUsage(id)
        if usage == nil,
           let event = try repo.latestOutboxEvent(taskID: id, eventType: "task.state_changed"),
           let payload = try? JSONDecoder().decode(StateChangedPayload.self,
                                                   from: Data(event.payload.utf8)) {
            usage = payload.usage
        }
        let running = runningTurns
            .filter { $0.hasPrefix(id.rawValue + ":") }
            .compactMap { EngineerID(rawValue: String($0.split(separator: ":")[1])) }
        let wakeups = (try repo.wakeups(id))
            .filter { $0.state == "pending" || $0.state == "running" }
            .map { WakeupInfo(engineer: $0.engineerID, reason: $0.reason,
                              state: $0.state) }
        let proposals = try repo.proposals(id)
        return TaskDetail(task: task,
                          participants: try repo.participants(id),
                          subtasks: try repo.subtasks(id),
                          usage: usage,
                          runningEngineers: running,
                          pendingWakeups: wakeups,
                          draftProposalCount: proposals.filter { $0.visibility == "draft" }.count,
                          publishedProposalCount: proposals.filter { $0.visibility == "published" }.count)
    }

    /// Artifact rows for a task (workshop.listArtifacts).
    public func listArtifacts(_ taskID: TaskID) throws -> [Artifact] {
        try repo.artifacts(taskID)
    }

    /// All usage samples for a task (workshop.listUsage).
    public func listUsage(_ taskID: TaskID) throws -> [UsageSampleRecord] {
        try repo.usageSamples(taskID)
    }

    public func readMessages(_ taskID: TaskID, afterSeq: Int64 = 0, limit: Int = 500) throws -> [Message] {
        try repo.messages(taskID, afterSeq: afterSeq, limit: min(limit, 500))
    }

    /// T31 paging: newest page when beforeSeq is nil, else the window before it.
    public func readMessagePage(_ taskID: TaskID, beforeSeq: Int64? = nil,
                                limit: Int = 500) throws -> [Message] {
        try repo.messagePage(taskID, beforeSeq: beforeSeq, limit: limit)
    }

    public func listEngineers() async -> [AdapterProbe] {
        var probes: [AdapterProbe] = []
        for engineer in EngineerID.allCases {
            if let adapter = adapters[engineer] {
                probes.append(await adapter.probe())
            } else {
                probes.append(AdapterProbe(engineer: engineer,
                                           health: .unavailable("adapter not configured")))
            }
        }
        return probes
    }

    public func outboxEvents(afterSeq: Int64) throws -> [OutboxEvent] {
        try repo.outboxEvents(afterSeq: afterSeq)
    }

    // MARK: - Commands

    /// Create a task: idempotent on `idempotency_key`; single commit for task + root
    /// message + participants + root subtask + outbox (spec §8.4/§8.5, T01/T02).
    public func createTask(_ request: CreateTaskRequest) throws -> CreateTaskReceipt {
        try checkStorage()
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkshopError.invalidRequest("title must not be empty")
        }
        guard !request.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkshopError.invalidRequest("objective must not be empty")
        }
        let payloadHash = try canonicalJSONHash(of: request)

        if let existing = try repo.operation(request.idempotencyKey) {
            if existing.payloadHash == payloadHash {
                let data = Data(existing.resultJSON.utf8)
                return try JSONDecoder().decode(CreateTaskReceipt.self, from: data)
            }
            throw WorkshopError.idempotencyConflict
        }

        let timestamp = now()
        let taskID = TaskID(newID("task"))
        let messageID = MessageID(newID("msg"))
        let subtaskID = SubtaskID(newID("sub"))

        let task = WorkshopTask(id: taskID, channel: request.channel, title: request.title,
                                brief: request.objective, phase: request.phase,
                                state: .queued, budgetPolicyRef: request.budgetPolicyRef,
                                createdAt: timestamp, updatedAt: timestamp)
        let rootMessage = Message(id: messageID, taskID: taskID, seq: 1, author: .user,
                                  kind: .text, body: request.objective,
                                  deliveryState: .committed,
                                  createdAt: timestamp, updatedAt: timestamp)
        let rootSubtask = Subtask(id: subtaskID, taskID: taskID, title: request.title,
                                  acceptance: request.acceptanceCriteria,
                                  state: .ready, createdAt: timestamp, updatedAt: timestamp)

        var receipt: CreateTaskReceipt?
        try repo.db.transaction {
            try repo.insertTask(task)
            try repo.insertMessage(rootMessage)
            for engineer in request.participants {
                try repo.insertParticipant(Participant(taskID: taskID, engineerID: engineer))
            }
            try repo.insertSubtask(rootSubtask)
            var seq = try repo.insertOutbox(
                taskID: taskID, eventType: "task.created",
                payload: #"{"task_id":""# + taskID.rawValue + #""}"#,
                deliveryState: "pending", at: timestamp)
            switch request.phase {
            case .execution, .followUp:
                seq = try repo.insertOutbox(
                    taskID: taskID, eventType: Self.dispatchRequested,
                    payload: #"{"task_id":""# + taskID.rawValue
                        + #"","subtask_id":""# + subtaskID.rawValue + #""}"#,
                    deliveryState: "pending", at: timestamp)
            case .researchProposal:
                // Substantial path (§5.3): Queued → Researching and every
                // participant is woken to draft an independent proposal.
                try transition(taskID, from: .queued, to: .researching, at: timestamp)
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "Research phase started; each participant drafts an "
                        + "independent proposal (private until published).",
                    deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
                for engineer in request.participants {
                    try repo.insertWakeup(taskID: taskID, engineerID: engineer,
                                          reason: "research_proposal",
                                          triggerSeq: nil, at: timestamp)
                }
            }
            let r = CreateTaskReceipt(taskID: taskID, committedSeq: seq, state: .queued,
                                      status: .created, deepLink: nil)
            let receiptJSON = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
            try repo.insertOperation(key: request.idempotencyKey, principal: "user",
                                     payloadHash: payloadHash, resultJSON: receiptJSON,
                                     at: timestamp)
            receipt = r
        }
        publishCommitted()
        scheduleDispatch()
        scheduleWakeupCoalescer()
        if request.phase == .researchProposal { scheduleResearchDeadline(taskID) }
        return receipt!
    }

    /// Append a message to an existing task; author identity comes from the
    /// connection principal, never from caller params (§9.3).
    @discardableResult
    public func postMessage(taskID: TaskID, body: String, principal: Principal = .user,
                            kind: MessageKind = .text, replyTo: MessageID? = nil,
                            structured: String? = nil) throws -> Message {
        guard try repo.task(taskID) != nil else { throw WorkshopError.taskNotFound(taskID) }
        if let engineer = principal.engineerID {
            try requireParticipant(engineer, taskID: taskID)
        }
        // Codex posts read as the user's entry point: author stays `user` and
        // the channel is recorded in structured (§9.3: display "You (via Codex)").
        var structured = structured
        var author = principal
        if principal == .codex {
            author = .user
            var fields = structured.flatMap {
                try? JSONDecoder().decode([String: JSONValue].self,
                                          from: Data($0.utf8))
            } ?? [:]
            fields["via"] = .string("codex")
            structured = String(decoding: (try? JSONEncoder().encode(fields))
                                    ?? Data(), as: UTF8.self)
        }
        let timestamp = now()
        let messageID = MessageID(newID("msg"))
        var committed: Message?
        try repo.db.transaction {
            let m = Message(id: messageID, taskID: taskID, seq: try repo.nextMessageSeq(taskID),
                            author: author, kind: kind, body: body, replyTo: replyTo,
                            deliveryState: .committed, structured: structured,
                            createdAt: timestamp, updatedAt: timestamp)
            try repo.insertMessage(m)
            committed = m
            try repo.insertOutbox(taskID: taskID, eventType: "message.committed",
                                  payload: #"{"message_id":""# + m.id.rawValue
                                      + #"","task_id":""# + taskID.rawValue + #""}"#,
                                  deliveryState: "pending", at: timestamp)
            try enqueueWakeups(for: m, at: timestamp)
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        return committed!
    }

    private func requireParticipant(_ engineer: EngineerID, taskID: TaskID) throws {
        guard try repo.participant(taskID, engineer) != nil else {
            throw WorkshopError.notAParticipant(engineer: engineer, task: taskID)
        }
    }

    // MARK: - Collaboration tools (spec §8.3)

    /// workshop_get_task for an engineer principal.
    public func toolGetTask(taskID: TaskID, principal: Principal) throws -> TaskDetail {
        if let engineer = principal.engineerID {
            try requireParticipant(engineer, taskID: taskID)
        }
        return try getTask(taskID)
    }

    /// workshop_read_messages for an engineer principal.
    public func toolReadMessages(taskID: TaskID, afterSeq: Int64, limit: Int,
                                 principal: Principal) throws -> [Message] {
        if let engineer = principal.engineerID {
            try requireParticipant(engineer, taskID: taskID)
        }
        // Provisional-seq rows are still streaming; engineers never see them.
        return try repo.messages(taskID, afterSeq: afterSeq, limit: limit)
            .filter { $0.deliveryState == .committed }
    }

    /// workshop_post_message: kind text|proposal|review|help_request|decision;
    /// help_request posts as text with a structured flag.
    public func toolPostMessage(taskID: TaskID, body: String, kind: String,
                                replyTo: MessageID?, principal: Principal) throws -> Message {
        let messageKind: MessageKind
        var structured: String?
        switch kind {
        case "help_request":
            messageKind = .text
            structured = #"{"help_request":true}"#
        case let raw:
            guard let parsed = MessageKind(rawValue: raw), parsed != .systemEvent else {
                throw WorkshopError.invalidRequest("unsupported kind: \(raw)")
            }
            messageKind = parsed
        }
        return try postMessage(taskID: taskID, body: body, principal: principal,
                               kind: messageKind, replyTo: replyTo, structured: structured)
    }

    /// workshop_request_review: posts a review-request message and wakes the target.
    public func toolRequestReview(taskID: TaskID, reviewer: EngineerID, message: String,
                                  principal: Principal) throws -> Message {
        if let engineer = principal.engineerID {
            try requireParticipant(engineer, taskID: taskID)
        }
        guard try repo.participant(taskID, reviewer) != nil else {
            throw WorkshopError.invalidRequest("reviewer is not a participant")
        }
        let structured = String(
            decoding: try JSONEncoder().encode(["reviewer": reviewer.rawValue]),
            as: UTF8.self)
        return try postMessage(taskID: taskID,
                               body: "@\(reviewer.rawValue) \(message)",
                               principal: principal, kind: .review, structured: structured)
    }

    /// workshop_get_capacity: real per-bucket snapshots (§10, T14).
    public func toolGetCapacity() -> JSONValue { capacitySnapshot() }

    /// Required keys of a schema_version 1 checkpoint (§6.3).
    private static let checkpointKeys = [
        "objective", "completed", "decisions", "artifacts", "validation",
        "unresolved", "next_action", "last_read_message_seq",
    ]

    /// workshop_save_checkpoint: validate schema/size/secret, then store
    /// (§6.3). Rejected bodies are still refused, not silently stored.
    public func toolSaveCheckpoint(taskID: TaskID, content: JSONValue,
                                   principal: Principal) throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("checkpoints require an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        try checkStorage(taskID: taskID)
        let data = try JSONEncoder().encode(content)
        guard data.count <= 64 * 1024 else {
            throw WorkshopError.invalidRequest("checkpoint exceeds 64 KiB")
        }
        guard Int(content["schema_version"]?.intValue ?? 0) == 1 else {
            throw WorkshopError.invalidRequest("checkpoint schema_version must be 1")
        }
        for key in Self.checkpointKeys where content[key] == nil {
            throw WorkshopError.invalidRequest("checkpoint missing key: \(key)")
        }
        let body = String(decoding: data, as: UTF8.self)
        if Redactor.shared.containsSecret(body) {
            throw WorkshopError.invalidRequest("checkpoint contains a secret; redact it")
        }
        let generation = Int(content["ownership_generation"]?.intValue ?? 0)
        let id = try repo.insertCheckpoint(taskID: taskID, engineerID: engineer,
                                           role: "main", workerID: "main",
                                           generation: generation,
                                           schemaVersion: 1,
                                           content: body,
                                           at: now())
        return .object(["checkpoint_id": .number(Double(id))])
    }

    /// Latest usable checkpoint for resume; a malformed stored row is marked
    /// valid=0 with a systemEvent and the earlier valid one is used (§6.3).
    public func loadValidCheckpoint(taskID: TaskID, engineerID: EngineerID)
        throws -> (id: Int64, content: String)? {
        guard let latest = try repo.latestCheckpoint(taskID: taskID,
                                                     engineerID: engineerID) else {
            return nil
        }
        let decoded = try? JSONDecoder().decode(JSONValue.self,
                                                from: Data(latest.content.utf8))
        if decoded == nil || latest.schemaVersion != 1 || !latest.valid {
            if latest.valid {
                try repo.markCheckpointInvalid(latest.id)
                let t = now()
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "Corrupt checkpoint skipped; using earlier valid checkpoint",
                    deliveryState: .committed, createdAt: t, updatedAt: t))
                publishCommitted()
            }
            guard let earlier = try repo.latestValidCheckpoint(taskID: taskID,
                                                             engineerID: engineerID)
            else { return nil }
            return (earlier.id, earlier.content)
        }
        return (latest.id, latest.content)
    }

    /// workshop_report_result: owner submits evidence at a claimed generation;
    /// subtask → review, task → verifying. Idempotent on (subtask, generation)
    /// and fenced on a stale generation (T05/T06).
    public func toolReportResult(taskID: TaskID, subtaskID: SubtaskID, summary: String,
                                 artifactIDs: [String], validation: [JSONValue],
                                 generation: Int?,
                                 principal: Principal) async throws -> Message {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("report_result requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        let task = try loadTask(taskID)
        try requireImplementationApproval(task)
        guard let generation else {
            throw WorkshopError.invalidRequest(
                "generation required (ownership_generation from the packet)")
        }
        // T06: idempotent retry returns the original structured message.
        if let existing = try repo.resultMessage(taskID: taskID,
                                                 subtaskID: subtaskID,
                                                 generation: generation) {
            return existing
        }
        guard let subtask = try repo.subtask(subtaskID), subtask.taskID == taskID,
              subtask.ownerID == engineer else {
            throw WorkshopError.notOwner
        }
        // T05: execution-boundary fencing — a stale generation is refused.
        guard generation == subtask.generation else {
            try emitFencedEvent(taskID: taskID, engineer: engineer,
                                supplied: generation,
                                current: subtask.generation)
            throw WorkshopError.staleGeneration(engineer: engineer,
                                                supplied: generation,
                                                current: subtask.generation)
        }
        let timestamp = now()
        let structured = String(
            decoding: try JSONEncoder().encode(JSONValue.object([
                "type": .string("result"),
                "subtask_id": .string(subtaskID.rawValue),
                "generation": .number(Double(subtask.generation)),
                "artifact_ids": .array(artifactIDs.map { .string($0) }),
                "validation": .array(validation),
            ])), as: UTF8.self)
        var committed: Message?
        try repo.db.transaction {
            let m = Message(id: MessageID(newID("msg")), taskID: taskID,
                            seq: try repo.nextMessageSeq(taskID), author: principal,
                            kind: .text, body: summary, deliveryState: .committed,
                            structured: structured, createdAt: timestamp, updatedAt: timestamp)
            try repo.insertMessage(m)
            committed = m
            try repo.updateSubtaskState(subtaskID, .review, at: timestamp)
            if let task = try repo.task(taskID), task.state == .working {
                try transition(taskID, from: .working, to: .verifying, at: timestamp)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent, body: "Owner reported complete; verification pending",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
            try repo.insertOutbox(taskID: taskID, eventType: "message.committed",
                                  payload: #"{"message_id":""# + m.id.rawValue
                                      + #"","task_id":""# + taskID.rawValue + #""}"#,
                                  deliveryState: "pending", at: timestamp)
        }
        publishCommitted()

        // Proportional review (§5.5): high-risk or research tasks get a
        // verifier ≠ owner; prefer Devin when it isn't the owner.
        if subtask.risk == "high" || task.phase == .researchProposal,
           let resultMessage = committed {
            let participants = (try repo.participants(taskID)).map(\.engineerID)
            var candidates = participants.filter { $0 != engineer }
            if candidates.contains(.devin) {
                candidates.removeAll { $0 == .devin }
                candidates.insert(.devin, at: 0)
            }
            var verifier: EngineerID?
            for candidate in candidates {
                if let adapter = adapters[candidate],
                   await adapter.probe().health.kind == .available {
                    verifier = candidate
                    break
                }
            }
            if let verifier {
                _ = try repo.insertWakeup(
                    taskID: taskID, engineerID: verifier,
                    reason: "verify_result:" + resultMessage.id.rawValue,
                    triggerSeq: resultMessage.seq, at: now())
                scheduleWakeupCoalescer()
            }
        }
        return committed!
    }

    /// workshop_publish_artifact: copy a workspace file into the artifact store with
    /// content-hash naming; path must resolve inside the task worktree (T26).
    /// Idempotent on (task, content_hash) — a duplicate returns the existing
    /// row (T06). Optional `generation` is fenced against the owned subtask's
    /// current generation: a stale artifact is quarantined under fenced/ and
    /// refused (T05) — never merged into the task's Files.
    public func toolPublishArtifact(taskID: TaskID, path: String, description: String?,
                                    generation: Int? = nil,
                                    principal: Principal) throws -> Artifact {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("publish_artifact requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        try requireImplementationApproval(try loadTask(taskID))
        try checkStorage(taskID: taskID)
        guard let homeDir else {
            throw WorkshopError.invalidRequest("no artifact store configured")
        }
        let workspace = try WorkspaceManager.worktreePath(homeDir: homeDir, taskID: taskID)
        let source = try WorkspaceManager.resolveInsideWorkspace(workspace, path)
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let baseName = (source as NSString).lastPathComponent

        // Fencing: when the caller supplies a generation, it must equal the
        // current generation of the subtask they own.
        if let generation {
            let owned = try repo.latestOwnedSubtask(taskID: taskID, owner: engineer)
            // Caller owns nothing (e.g. after reassignment): the "current"
            // generation for the event is the task's highest generation.
            let current = owned?.generation
                ?? ((try? repo.subtasks(taskID).map(\.generation).max()) ?? -1)
            if generation != current {
                // Quarantine the bytes anyway — never merge into Files.
                let fencedDir = homeDir + "/artifacts/" + taskID.rawValue + "/fenced"
                try FileManager.default.createDirectory(
                    atPath: fencedDir, withIntermediateDirectories: true)
                let fenced = fencedDir + "/" + String(hash.prefix(16)) + "-" + baseName
                try? data.write(to: URL(fileURLWithPath: fenced), options: .atomic)
                try emitFencedEvent(taskID: taskID, engineer: engineer,
                                    supplied: generation, current: current)
                throw WorkshopError.staleGeneration(engineer: engineer,
                                                    supplied: generation,
                                                    current: current)
            }
        }

        // T06: content-hash idempotency returns the existing row.
        if let existing = try repo.artifactByHash(taskID: taskID, contentHash: hash) {
            return existing
        }

        let artifactID = "art_" + UUID().uuidString.lowercased()
        let destDir = homeDir + "/artifacts/" + taskID.rawValue
        let dest = destDir + "/" + String(hash.prefix(16)) + "-" + baseName
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        // Write via temp + fsync + rename for crash safety.
        let tmp = destDir + "/.tmp-" + artifactID
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
        try fh.synchronize(); try fh.close()
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(atPath: tmp)
        } else {
            try FileManager.default.moveItem(atPath: tmp, toPath: dest)
        }
        let owned = try repo.latestOwnedSubtask(taskID: taskID, owner: engineer)
        let artifact = Artifact(id: artifactID, taskID: taskID, contentHash: hash,
                                relativePath: "artifacts/\(taskID.rawValue)/\(String(hash.prefix(16)))-\(baseName)",
                                producer: engineer.rawValue, description: description,
                                generation: owned?.generation, createdAt: now())
        try repo.db.transaction { try repo.insertArtifact(artifact) }
        return artifact
    }

    /// System event recorded when stale-generation work is fenced (T05).
    private func emitFencedEvent(taskID: TaskID, engineer: EngineerID,
                                 supplied: Int, current: Int) throws {
        let t = now()
        try repo.insertMessage(Message(
            id: MessageID(newID("msg")), taskID: taskID,
            seq: try repo.nextMessageSeq(taskID), author: .system,
            kind: .systemEvent,
            body: "Fenced stale result from \(engineer.displayName) "
                + "(generation \(supplied), current \(current))",
            deliveryState: .committed, createdAt: t, updatedAt: t))
        publishCommitted()
    }

    /// Unified entry point for the §8.3 collaboration tools — used by the IPC
    /// daemon, the workshop-mcp bridge, and the DeepSeek tool loop. Author
    /// identity always comes from `principal`, never from args.
    /// Tools the Codex principal may call (§9.3, ADR 0015): task entry and
    /// read/follow-up only — approvals, allocation, acceptance stay user-only.
    private static let codexTools: Set<String> = [
        "workshop_create_task", "workshop_list_tasks", "workshop_get_task",
        "workshop_read_messages", "workshop_post_message",
    ]

    /// Set by the daemon after verifying `workshop://` is registered to
    /// ai.maapu.workshop; receipts report the deep link truthfully.
    public nonisolated(unsafe) var deepLinkHandlerVerified = false

    /// identity always comes from `principal`, never from args.
    public func callTool(_ name: String, args: JSONValue,
                         principal: Principal) async throws -> JSONValue {
        if principal == .codex && !Self.codexTools.contains(name) {
            throw WorkshopError.userAuthorityRequired(
                "Codex may create and follow up tasks; approval, allocation, "
                    + "and acceptance stay with the user in the app")
        }
        switch name {
        case "workshop_create_task":
            let request: CreateTaskRequest
            do {
                request = try args.decode(as: CreateTaskRequest.self)
            } catch {
                throw WorkshopError.invalidRequest(
                    "workshop_create_task requires idempotency_key, title, "
                        + "objective, phase")
            }
            let receipt = try createTask(request)
            // status = the task's dispatch position right now (§8.4):
            // created | queued | running.
            let current = try repo.task(receipt.taskID)?.state ?? receipt.state
            let status: CreateTaskStatus = switch current {
            case .working, .researching, .verifying: .running
            case .queued, .paused: .queued
            default: receipt.status
            }
            var out: [String: JSONValue] = [
                "task_id": .string(receipt.taskID.rawValue),
                "committed_seq": .number(Double(receipt.committedSeq)),
                "state": .string(receipt.state.rawValue),
                "status": .string(status.rawValue),
            ]
            if deepLinkHandlerVerified {
                out["deep_link"] = .string("workshop://task/"
                    + receipt.taskID.rawValue)
            } else {
                out["deep_link"] = .null
                out["deep_link_note"] = .string(
                    "workshop:// scheme not yet registered to Workshop.app")
            }
            return .object(out)
        case "workshop_list_tasks":
            return try .from(try listTasks())
        case "workshop_get_task":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try .from(try toolGetTask(taskID: id, principal: principal))
        case "workshop_read_messages":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try .from(try toolReadMessages(
                taskID: id, afterSeq: args["after_seq"]?.intValue ?? 0,
                limit: Int(args["limit"]?.intValue ?? 200), principal: principal))
        case "workshop_post_message":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let body = args["body"]?.stringValue else {
                throw WorkshopError.invalidRequest("body required")
            }
            return try .from(try toolPostMessage(
                taskID: id, body: body, kind: args["kind"]?.stringValue ?? "text",
                replyTo: args["reply_to"]?.stringValue.map { MessageID($0) },
                principal: principal))
        case "workshop_request_review":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let reviewerRaw = args["reviewer"]?.stringValue,
                  let reviewer = EngineerID(rawValue: reviewerRaw),
                  let message = args["message"]?.stringValue else {
                throw WorkshopError.invalidRequest("reviewer and message required")
            }
            return try .from(try toolRequestReview(taskID: id, reviewer: reviewer,
                                                   message: message, principal: principal))
        case "workshop_publish_artifact":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let path = args["path"]?.stringValue else {
                throw WorkshopError.invalidRequest("path required")
            }
            return try .from(try toolPublishArtifact(
                taskID: id, path: path,
                description: args["description"]?.stringValue,
                generation: args["generation"]?.intValue.map(Int.init),
                principal: principal))
        case "workshop_report_result":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            let subtaskID = SubtaskID(args["subtask_id"]?.stringValue ?? "")
            guard let summary = args["summary"]?.stringValue else {
                throw WorkshopError.invalidRequest("summary required")
            }
            return try .from(try await toolReportResult(
                taskID: id, subtaskID: subtaskID, summary: summary,
                artifactIDs: args["artifact_ids"]?.arrayValue?
                    .compactMap { $0.stringValue } ?? [],
                validation: args["validation"]?.arrayValue ?? [],
                generation: args["generation"]?.intValue.map(Int.init),
                principal: principal))
        case "workshop_get_capacity":
            return toolGetCapacity()
        case "workshop_save_checkpoint":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            var content = args
            if case .object(var obj) = content {
                obj.removeValue(forKey: "task_id")
                content = .object(obj)
            }
            return try toolSaveCheckpoint(taskID: id, content: content, principal: principal)
        case "workshop_submit_proposal":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try await toolSubmitProposal(taskID: id, content: args,
                                                principal: principal)
        case "workshop_read_proposals":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try .from(try toolReadProposals(taskID: id, principal: principal))
        case "workshop_submit_review":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let proposalID = args["proposal_id"]?.stringValue,
                  let body = args["body"]?.stringValue else {
                throw WorkshopError.invalidRequest("proposal_id and body required")
            }
            return try .from(try await toolSubmitReview(
                taskID: id, proposalID: proposalID,
                severity: args["severity"]?.stringValue ?? "low",
                disposition: args["disposition"]?.stringValue ?? "agree",
                body: body, evidence: args["evidence"]?.stringValue,
                principal: principal))
        case "workshop_submit_report":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try await toolSubmitReport(taskID: id, content: args,
                                              principal: principal)
        case "workshop_assign_subtask":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let ownerRaw = args["owner"]?.stringValue,
                  let owner = EngineerID(rawValue: ownerRaw) else {
                throw WorkshopError.invalidRequest("owner required")
            }
            return try await toolAssignSubtask(
                taskID: id, subtaskID: SubtaskID(args["subtask_id"]?.stringValue ?? ""),
                owner: owner, rationale: args["rationale"]?.stringValue ?? "",
                expectedGeneration: args["expected_generation"]?.intValue.map(Int.init),
                principal: principal)
        case "workshop_claim_subtask":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try await toolClaimSubtask(
                taskID: id, subtaskID: SubtaskID(args["subtask_id"]?.stringValue ?? ""),
                principal: principal)
        case "workshop_propose_subtask":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let title = args["title"]?.stringValue else {
                throw WorkshopError.invalidRequest("title required")
            }
            let acceptance = args["acceptance_criteria"]?.arrayValue?
                .compactMap { $0.stringValue } ?? []
            let depends = args["depends_on"]?.arrayValue?
                .compactMap { $0.stringValue } ?? []
            return try await toolProposeSubtask(
                taskID: id, title: title, acceptanceCriteria: acceptance,
                proposedOwner: args["proposed_owner"]?.stringValue
                    .flatMap(EngineerID.init(rawValue:)),
                risk: args["risk"]?.stringValue, dependsOn: depends,
                principal: principal)
        case "workshop_dispute_assignment":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            guard let body = args["body"]?.stringValue else {
                throw WorkshopError.invalidRequest("body required")
            }
            return try await toolDisputeAssignment(
                taskID: id, subtaskID: SubtaskID(args["subtask_id"]?.stringValue ?? ""),
                body: body, principal: principal)
        case "workshop_escalate_task":
            let id = TaskID(args["task_id"]?.stringValue ?? "")
            return try await toolEscalateTask(
                taskID: id, reason: args["reason"]?.stringValue ?? "",
                principal: principal)
        case "workshop_acquire_lease":
            return try toolAcquireLease(args: args, principal: principal)
        case "workshop_renew_lease":
            return try toolRenewLease(args: args, principal: principal)
        case "workshop_release_lease":
            return try toolReleaseLease(args: args, principal: principal)
        default:
            throw WorkshopError.methodNotFound(name)
        }
    }

    // MARK: - Wakeups (§5.4)

    /// Compute wakeup targets for a committed message and insert pending rows.
    /// Must be called inside the committing transaction.
    private func enqueueWakeups(for message: Message, at timestamp: Date) throws {
        let participants = try repo.participants(message.taskID)
        let participantIDs = Set(participants.map(\.engineerID))
        var targets: [(EngineerID, String)] = []

        switch message.author {
        case .system:
            return // system events never wake anyone
        case .codex:
            return // stored as .user with via=codex; never a row author
        case .user:
            // A user reply wakes the current owner (T10).
            if let owner = try repo.subtasks(message.taskID).lazy
                .compactMap(\.ownerID).first, participantIDs.contains(owner) {
                targets.append((owner, "user_message"))
            }
        case .engineer(let author):
            // Explicit @mentions of other participants.
            for engineer in EngineerID.allCases where engineer != author {
                if message.body.contains("@\(engineer.rawValue)"),
                   participantIDs.contains(engineer) {
                    targets.append((engineer, "mention"))
                }
            }
            // A review request wakes its target.
            if message.kind == .review, let structured = message.structured,
               let value = try? JSONDecoder().decode(JSONValue.self,
                                                     from: Data(structured.utf8)),
               let reviewerRaw = value["reviewer"]?.stringValue,
               let reviewer = EngineerID(rawValue: reviewerRaw),
               reviewer != author, participantIDs.contains(reviewer),
               !targets.contains(where: { $0.0 == reviewer }) {
                targets.append((reviewer, "review_request"))
            }
        }

        for (engineer, reason) in targets {
            // Loop bound (T11): suppress after N consecutive engineer-triggered
            // wakeups without an intervening user message. User messages always go.
            if reason != "user_message",
               try repo.engineerWakeupsSinceLastUserMessage(message.taskID) >= wakeupLoopBound {
                try repo.insertWakeup(taskID: message.taskID, engineerID: engineer,
                                      reason: reason, triggerSeq: message.seq,
                                      state: "suppressed", at: timestamp)
                continue
            }
            try repo.insertWakeup(taskID: message.taskID, engineerID: engineer,
                                  reason: reason, triggerSeq: message.seq, at: timestamp)
        }
        // One system event per task when suppression kicks in.
        if targets.contains(where: { $0.1 != "user_message" }),
           try repo.engineerWakeupsSinceLastUserMessage(message.taskID) >= wakeupLoopBound,
           !(try repo.messages(message.taskID).contains {
               $0.body == "Discussion round limit reached; waiting for user" }) {
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: message.taskID,
                seq: try repo.nextMessageSeq(message.taskID), author: .system,
                kind: .systemEvent,
                body: "Discussion round limit reached; waiting for user",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
        }
    }

    private func scheduleWakeupCoalescer() {
        guard !wakeupScheduled, !isShutdown else { return }
        wakeupScheduled = true
        Task { await self.runWakeupCoalescer() }
    }

    /// After the coalescing delay, run one turn per (task, engineer) covering all
    /// pending wakeup rows; in-flight pairs stay pending until the turn finishes.
    private func runWakeupCoalescer() async {
        if wakeupCoalescence > .zero {
            try? await Task.sleep(for: wakeupCoalescence)
        }
        defer { wakeupScheduled = false }
        while !isShutdown {
            guard let pending = attempt("pendingWakeups", { try repo.pendingWakeups() }),
                  !pending.isEmpty else { break }
            var groups: [String: (taskID: TaskID, engineer: EngineerID,
                                 reasons: [String], rows: [Int64])] = [:]
            var order: [String] = []
            for row in pending {
                let key = row.taskID.rawValue + ":" + row.engineerID.rawValue
                if groups[key] == nil {
                    groups[key] = (row.taskID, row.engineerID, [], [])
                    order.append(key)
                }
                groups[key]!.rows.append(row.id)
                groups[key]!.reasons.append(row.reason)
            }
            var anyPending = false
            for key in order {
                guard let group = groups[key] else { continue }
                if runningTurns.contains(key) { anyPending = true; continue }
                let task: WorkshopTask? = attempt("wakeupTask",
                                                  { try repo.task(group.taskID) }) ?? nil
                guard let adapter = adapters[group.engineer], let task else {
                    for id in group.rows {
                        _ = attempt("wakeupSuppressed",
                                    { try repo.setWakeupState(id, "suppressed",
                                                              at: now()) })
                    }
                    continue
                }
                let probe = await adapter.probe()
                guard probe.health.kind == .available else {
                    for id in group.rows {
                        _ = attempt("wakeupSuppressed",
                                    { try repo.setWakeupState(id, "suppressed",
                                                              at: now()) })
                    }
                    let timestamp = now()
                    let unavailableBody: String
                    if group.reasons.contains("consolidate") {
                        // §5.3: no other engineer is promoted to arbiter.
                        unavailableBody = "Consolidated report waits for "
                            + "\(group.engineer.displayName) (unavailable: "
                            + "\(probe.health.detail)) or a user override"
                    } else {
                        unavailableBody = "\(group.engineer.rawValue.capitalized) was "
                            + "mentioned but is \(probe.health.detail); not woken"
                    }
                    _ = attempt("wakeupUnavailableEvent") {
                        try repo.insertMessage(Message(
                            id: MessageID(newID("msg")), taskID: task.id,
                            seq: try repo.nextMessageSeq(task.id), author: .system,
                            kind: .systemEvent, body: unavailableBody,
                            deliveryState: .committed, createdAt: timestamp,
                            updatedAt: timestamp))
                    }
                    continue
                }
                for id in group.rows {
                    _ = attempt("wakeupRunning",
                                { try repo.setWakeupState(id, "running", at: now()) })
                }
                let owned: Subtask? = attempt("wakeupSubtask", {
                    try repo.latestOwnedSubtask(taskID: task.id, owner: group.engineer)
                }) ?? nil
                let fallback: Subtask? = attempt("wakeupFallbackSubtask", {
                    try repo.subtasks(task.id).first
                }) ?? nil
                await runTurn(adapter: adapter, engineer: group.engineer, task: task,
                              subtask: owned ?? fallback,
                              wakeReason: group.reasons.last)
                for id in group.rows {
                    _ = attempt("wakeupDone",
                                { try repo.setWakeupState(id, "done", at: now()) })
                }
            }
            // Another batch may have arrived while we ran turns; loop if so, else exit.
            if !anyPending {
                let more = attempt("pendingWakeups", { try repo.pendingWakeups() }) ?? []
                if more.isEmpty { break }
            }
            // In-flight turn groups stay pending; don't busy-poll them.
            try? await Task.sleep(for: max(wakeupCoalescence, .milliseconds(20)))
        }
    }

    // MARK: - Recovery

    /// Mark messages left `streaming` by a previous process as committed + uncertain,
    /// and block the owning subtask/task for reconciliation.
    private func recoverInterruptedStreams() {
        guard let interrupted = attempt("streamingMessages", { try repo.streamingMessages() }),
              !interrupted.isEmpty else { return }
        let timestamp = now()
        for message in interrupted {
            _ = attempt("recoverInterruptedStream") {
                try repo.db.transaction {
                    try repo.updateMessageBody(
                        message.id,
                        body: message.body
                            + "\n\n[stream interrupted by service restart; marked uncertain]",
                        at: timestamp)
                    if message.seq >= WorkshopRepository.provisionalSeqBase {
                        try repo.reassignMessageSeq(
                            message.id, seq: try repo.nextMessageSeq(message.taskID),
                            at: timestamp)
                    }
                    try repo.updateMessageDelivery(message.id, .committed, at: timestamp)
                    if let authorID = message.author.engineerID,
                       let subtask = try repo.latestOwnedSubtask(taskID: message.taskID,
                                                               owner: authorID) {
                        try repo.updateSubtaskState(subtask.id, .blocked, at: timestamp)
                    }
                    // F2: the message must reflect what actually happened — only
                    // claim "blocked" when the working→blocked transition ran.
                    var transitioned = false
                    if let task = try repo.task(message.taskID), task.state == .working {
                        try transition(message.taskID, from: .working, to: .blocked,
                                       at: timestamp)
                        transitioned = true
                    }
                    let detail = transitioned
                        ? "task blocked pending reconciliation (Phase 4)"
                        : "task remains \(try repo.task(message.taskID)?.state.displayName.lowercased() ?? "unknown")"
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: message.taskID,
                        seq: try repo.nextMessageSeq(message.taskID), author: .system,
                        kind: .systemEvent,
                        body: "Interrupted stream marked uncertain after service "
                            + "restart; \(detail)",
                        deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
                }
            }
        }
        publishCommitted()
    }

    // MARK: - Dispatcher

    private func scheduleDispatch() {
        guard dispatcherEnabled, !dispatcherScheduled, !isShutdown else { return }
        dispatcherScheduled = true
        Task { await self.dispatchLoop() }
    }

    private func dispatchLoop() async {
        while !isShutdown {
            guard let rows = attempt("pendingOutbox",
                                     { try repo.pendingOutbox(eventType: Self.dispatchRequested) }),
                  let row = rows.first else { break }
            if let failure = await handleDispatch(row) {
                let marked = attempt("markOutboxFailed") {
                    try repo.db.transaction {
                        try repo.markOutboxFailed(row.seq, reason: failure, at: now())
                    }
                }
                if marked == nil { break } // cannot mark — do not spin on the row
            }
        }
        dispatcherScheduled = false
    }

    /// Exposed for tests that drive the dispatcher manually.
    public func processPendingDispatches() async {
        await dispatchLoop()
    }

    /// Test hook: all wakeup rows for a task, any state.
    public func wakeupsForTest(_ taskID: TaskID) throws -> [WorkshopRepository.Wakeup] {
        try repo.wakeups(taskID)
    }

    /// Test hook: run the CAS claim directly (concurrent callers → exactly one winner).
    public func claimForTest(subtaskID: SubtaskID, owner: EngineerID,
                             expectedGeneration: Int) throws -> Bool {
        try repo.claimSubtask(subtaskID, owner: owner, expectedGeneration: expectedGeneration,
                              leaseExpiresAt: now().addingTimeInterval(300), at: now())
    }

    // MARK: - Phase 4 test hooks

    public func outboxCursorForTest(_ consumer: String) throws -> Int64 {
        try repo.outboxCursor(consumer)
    }

    /// Pending broadcast rows (everything except dispatcher-owned dispatch).
    public func pendingBroadcastForTest() throws -> [OutboxEvent] {
        try repo.db.query("""
            SELECT * FROM outbox WHERE delivery_state='pending'
              AND event_type != ?
            """, [.text(Self.dispatchRequested)]).map {
            OutboxEvent(seq: $0["seq"]!.int ?? 0,
                        taskID: $0["task_id"]?.text.map { TaskID($0) },
                        eventType: $0["event_type"]!.text!,
                        recipients: [],
                        payload: $0["payload"]!.text!,
                        deliveryState: "pending",
                        createdAt: WorkshopTime.date($0["created_at"]!.text!),
                        deliveredAt: nil)
        }
    }

    public func insertTurnForTest(taskID: TaskID, subtaskID: SubtaskID?,
                                  engineer: EngineerID, generation: Int) throws {
        try repo.insertTurn(Turn(id: newID("turnrow"), taskID: taskID,
                                 subtaskID: subtaskID, engineerID: engineer,
                                 generation: generation, state: "running",
                                 startedAt: now()))
    }

    public func turnsForTest(_ taskID: TaskID,
                             state: String? = nil) throws -> [Turn] {
        try repo.turns(taskID: taskID, state: state)
    }

    public func reservationsForTest(state: String) throws -> [Reservation] {
        try repo.reservations(state: state)
    }

    public func heldReservationTotalForTest(_ engineer: EngineerID) throws -> Int {
        try repo.heldReservationTotal(engineer.rawValue)
    }

    public func insertUsageForTest(taskID: TaskID, engineer: EngineerID,
                                   tokens: Int) throws {
        try repo.insertUsageSample(taskID: taskID, engineerID: engineer,
            provider: engineer.rawValue, model: nil, nativeSessionID: nil,
            turnID: nil,
            sample: UsageSample(input: tokens, output: 0, cacheRead: 0,
                                cacheWrite: 0, source: "test"),
            at: now())
    }

    public func insertNilUsageForTest(taskID: TaskID, engineer: EngineerID) throws {
        try repo.insertUsageSample(taskID: taskID, engineerID: engineer,
            provider: engineer.rawValue, model: nil, nativeSessionID: nil,
            turnID: nil,
            sample: UsageSample(input: nil, output: nil, cacheRead: nil,
                                cacheWrite: nil, source: "test"),
            at: now())
    }

    public func insertHeldReservationForTest(taskID: TaskID,
                                             engineer: EngineerID) throws {
        try repo.insertReservation(Reservation(
            id: newID("res"), taskID: taskID, engineerID: engineer,
            bucket: engineer.rawValue, reserved: 100,
            expiresAt: now().addingTimeInterval(300), createdAt: now()))
    }

    @discardableResult
    public func insertWakeupForTest(taskID: TaskID, engineer: EngineerID,
                                    reason: String, state: String) throws -> Int64 {
        try repo.insertWakeup(taskID: taskID, engineerID: engineer,
                              reason: reason, triggerSeq: nil,
                              state: state, at: now())
    }

    /// Inject a malformed checkpoint row (T06 corrupt-skip test).
    public func insertCorruptCheckpointForTest(taskID: TaskID,
                                               engineer: EngineerID) throws {
        try repo.db.execute("""
            INSERT INTO checkpoints(task_id, engineer_id, role, worker_id,
                                    generation, schema_version, content, valid,
                                    created_at)
            VALUES(?,?,?,?,?,?,?,1,?)
            """, [.text(taskID.rawValue), .text(engineer.rawValue),
                  .text("main"), .text("main"), .integer(0), .integer(1),
                  .text("{not valid json"), .text(WorkshopTime.string(now()))])
    }

    /// Insert N committed messages directly (T31 pagination test).
    public func insertMessagesForTest(taskID: TaskID, count: Int) throws {
        try repo.db.transaction {
            for i in 0..<count {
                let t = now()
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .user,
                    kind: .text, body: "bulk message \(i)",
                    deliveryState: .committed, createdAt: t, updatedAt: t))
            }
        }
    }

    /// Test hook: force a task state without checking the §8.2 edge.
    public func setTaskStateForTest(_ taskID: TaskID, _ state: TaskState) throws {
        try repo.updateTaskState(taskID, state, at: now())
    }

    /// Run a turn directly (no dispatch); concurrent=true detaches it.
    public func runTurnForTest(engineer: EngineerID, taskID: TaskID,
                               concurrent: Bool = false) async {
        guard let adapter = adapters[engineer],
              let task = try? repo.task(taskID) else { return }
        let sub = try? repo.latestOwnedSubtask(taskID: taskID, owner: engineer)
        if concurrent {
            Task {
                await self.runTurn(adapter: adapter, engineer: engineer,
                                   task: task, subtask: sub, wakeReason: "assigned")
            }
        } else {
            await runTurn(adapter: adapter, engineer: engineer, task: task,
                          subtask: sub, wakeReason: "assigned")
        }
    }

    /// Test hook: simulate a crashed mid-turn state — claimed subtask, working task,
    /// and an uncommitted streaming message. `forceWorking: false` leaves the task
    /// in its current state (tests the non-transitioning recovery message, F2).
    public func insertStreamingMessageForTest(forceWorking: Bool = true) throws {
        guard let task = try repo.listTasks().first else { return }
        let timestamp = now()
        try repo.db.transaction {
            if forceWorking {
                if let subtask = try repo.subtasks(task.id).first {
                    _ = try repo.claimSubtask(subtask.id, owner: .devin,
                                              expectedGeneration: subtask.generation,
                                              leaseExpiresAt: timestamp.addingTimeInterval(300),
                                              at: timestamp)
                }
                var state = task.state
                for next in [TaskState.ready, .working] where state != next {
                    try transition(task.id, from: state, to: next, at: timestamp)
                    state = next
                }
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: task.id,
                seq: try repo.nextMessageSeq(task.id), author: .engineer(.devin),
                kind: .text, body: "partial reply", deliveryState: .streaming,
                createdAt: timestamp, updatedAt: timestamp))
        }
    }

    /// Test hook: insert a raw pending dispatch.requested row (e.g. a poisoned payload).
    public func insertOutboxForTest(eventType: String, taskID: TaskID?, payload: String) throws {
        _ = try repo.insertOutbox(taskID: taskID, eventType: eventType, payload: payload,
                                  deliveryState: "pending", at: now())
    }

    /// Returns nil on success, or a failure reason for the outbox row.
    private func handleDispatch(_ row: OutboxEvent) async -> String? {
        guard let payload = try? JSONDecoder().decode(JSONValue.self,
                                                      from: Data(row.payload.utf8)),
              let taskIDRaw = payload["task_id"]?.stringValue,
              let subtaskIDRaw = payload["subtask_id"]?.stringValue else {
            return "invalid dispatch payload"
        }
        let taskID = TaskID(taskIDRaw)
        let subtaskID = SubtaskID(subtaskIDRaw)
        let preferredOwner = payload["preferred_owner"]?.stringValue
            .flatMap(EngineerID.init(rawValue:))

        guard let taskOpt = attempt("task", { try repo.task(taskID) }), let task = taskOpt,
              let subOpt = attempt("subtask", { try repo.subtask(subtaskID) }),
              var subtask = subOpt else {
            return "task or subtask not found"
        }

        // Eligible engineers: participants whose probe reports available (spec §5.2).
        var order = EngineerID.allCases
        if let preferredOwner, let index = order.firstIndex(of: preferredOwner) {
            order.remove(at: index)
            order.insert(preferredOwner, at: 0)
        }
        let participantIDs = attempt("participants", { try repo.participants(taskID) })?
            .map(\.engineerID) ?? []
        var winner: EngineerID?
        for engineer in order where participantIDs.contains(engineer) {
            guard let adapter = adapters[engineer] else { continue }
            // §10: a critical/limited bucket is skipped; unknown is allowed.
            let capacity = measureCapacity(engineer)?.availability ?? "unknown"
            if capacity == "critical" || capacity == "limited" { continue }
            // T15: probes are throttled to at most one per engineer per 5 min.
            let probe: AdapterProbe
            if let last = lastProbeAt[engineer],
               now().timeIntervalSince(last) < 300,
               let cached = lastProbes[engineer] {
                probe = cached
            } else {
                probe = await adapter.probe()
                lastProbeAt[engineer] = now()
                lastProbes[engineer] = probe
            }
            if probe.health.kind == .available {
                winner = engineer
                break
            }
        }

        guard let winner, let adapter = adapters[winner] else {
            // No eligible engineer: durable task, blocked once with a system
            // event; dispatch does not retry (T15 — re-probe is the 5-min
            // throttle above, not a storm).
            let timestamp = now()
            let ok = attempt("noEligibleCommit") {
                try repo.db.transaction {
                    try transition(taskID, from: task.state, to: .ready, at: timestamp)
                    try transition(taskID, from: .ready, to: .working, at: timestamp)
                    try transition(taskID, from: .working, to: .blocked, at: timestamp)
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: taskID,
                        seq: try repo.nextMessageSeq(taskID), author: .system,
                        kind: .systemEvent, body: "No eligible engineer available",
                        deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
                    try repo.insertOutbox(taskID: taskID, eventType: "task.state_changed",
                                          payload: #"{"task_id":""# + taskID.rawValue
                                              + #"","state":"blocked"}"#,
                                          deliveryState: "pending", at: timestamp)
                    try repo.markOutboxDelivered(row.seq, at: timestamp)
                }
            }
            publishCommitted()
            return ok == nil ? "no-eligible commit failed" : nil
        }

        // Atomic CAS claim; changes()==1 is the single winner (T04).
        let timestamp = now()
        let lease = timestamp.addingTimeInterval(300)
        var claimed = false
        let ok = attempt("claimCommit") {
            try repo.db.transaction {
                claimed = try repo.claimSubtask(subtaskID, owner: winner,
                                              expectedGeneration: subtask.generation,
                                              leaseExpiresAt: lease, at: timestamp)
                guard claimed else { return }
                try repo.markOutboxDelivered(row.seq, at: timestamp)
                try transition(taskID, from: task.state, to: .ready, at: timestamp)
                try transition(taskID, from: .ready, to: .working, at: timestamp)
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system, kind: .systemEvent,
                    body: "\(winner.displayName) claimed \(subtask.title) (generation \(subtask.generation + 1))",
                    deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
                try repo.insertOutbox(taskID: taskID, eventType: "subtask.claimed",
                                      payload: #"{"subtask_id":""# + subtaskID.rawValue
                                          + #"","owner":""# + winner.rawValue
                                          + #"","generation":\#(subtask.generation + 1)}"#,
                                      deliveryState: "pending", at: timestamp)
            }
        }
        publishCommitted()
        guard ok != nil else { return "claim transaction failed" }
        guard claimed else { return "claim lost or subtask already owned" }

        if let reloaded: Subtask? = attempt("subtaskReload", { try repo.subtask(subtaskID) }),
           let reloaded {
            subtask = reloaded
        }

        // Run the turn outside the claim transaction.
        inflightTurns += 1
        defer { inflightTurns -= 1 }
        await runTurn(adapter: adapter, engineer: winner, task: task, subtask: subtask,
                      wakeReason: nil)
        return nil
    }

    /// Transition helper: verifies the §8.2 edge, no-op when already at `to`.
    private func transition(_ taskID: TaskID, from: TaskState, to: TaskState, at timestamp: Date) throws {
        if from == to { return }
        guard from.canTransition(to: to) else {
            throw WorkshopError.illegalTransition(from: from, to: to)
        }
        try repo.updateTaskState(taskID, to, at: timestamp)
    }

    /// Payload of a task.state_changed outbox event; usage nulls stay null.
    private struct StateChangedPayload: Codable {
        var task_id: String
        var state: String
        var usage: UsageSample?
    }

    /// Run one adapter turn. `wakeReason == nil` is the owner-execution turn
    /// (subtask → review, task → verifying on success); non-nil is a discussion
    /// wakeup turn which only commits a reply message.
    private func runTurn(adapter: EngineerAdapter, engineer: EngineerID,
                         task: WorkshopTask, subtask: Subtask?,
                         wakeReason: String?) async {
        let turnKey = task.id.rawValue + ":" + engineer.rawValue
        runningTurns.insert(turnKey)
        defer { runningTurns.remove(turnKey) }

        let timestamp = now()

        // §10/T13: capacity gate — a limited/critical bucket blocks dispatch
        // once (one systemEvent per task+bucket), with no retry storm.
        if let block = capacityBlock(for: engineer, taskID: task.id, at: timestamp) {
            if block != "suppressed" {
                _ = attempt("capacityBlockedEvent") {
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: task.id,
                        seq: try repo.nextMessageSeq(task.id), author: .system,
                        kind: .systemEvent, body: block, deliveryState: .committed,
                        createdAt: timestamp, updatedAt: timestamp))
                }
                publishCommitted()
            }
            return
        }
        let binding = SessionBinding(taskID: task.id, engineerID: engineer, role: "owner",
                                     workerID: "main")
        // Reuse a persisted native session binding when present (§6.2).
        var bound = binding
        if let stored: WorkshopRepository.SessionBindingRecord =
            attempt("sessionBinding", {
                try repo.sessionBinding(taskID: task.id, engineerID: engineer,
                                        role: "owner", workerID: "main")
            }) ?? nil {
            bound.nativeSessionID = stored.nativeSessionID
            bound.modelSelection = stored.modelSelection
            bound.recoveryState = stored.recoveryState
        }
        let ref: SessionRef
        do {
            ref = try await adapter.openTaskSession(binding: bound)
            if ref.nativeSessionID != bound.nativeSessionID {
                bound.nativeSessionID = ref.nativeSessionID
                bound.recoveryState = "bound"
                _ = attempt("saveSessionBinding") {
                    try repo.saveSessionBinding(.init(
                        taskID: bound.taskID, engineerID: bound.engineerID,
                        role: bound.role, workerID: bound.workerID,
                        nativeSessionID: bound.nativeSessionID,
                        profileRevision: bound.profileRevision,
                        modelSelection: bound.modelSelection,
                        recoveryState: bound.recoveryState))
                }
            }
        } catch {
            log.error("openTaskSession failed for \(engineer.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            _ = attempt("openFailedEvent") {
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: task.id,
                    seq: try repo.nextMessageSeq(task.id), author: .system,
                    kind: .systemEvent,
                    body: "Turn could not start for \(engineer.displayName): "
                        + error.localizedDescription,
                    deliveryState: .committed, createdAt: timestamp,
                    updatedAt: timestamp))
            }
            return
        }

        // Streaming placeholder gets a provisional seq (≥ provisionalSeqBase)
        // so it sorts last while streaming and never takes a real slot (F1).
        let messageID = MessageID(newID("msg"))
        _ = attempt("insertStreamingMessage") {
            try repo.db.transaction {
                try repo.insertMessage(Message(
                    id: messageID, taskID: task.id,
                    seq: try repo.nextProvisionalSeq(),
                    author: .engineer(engineer), kind: .text, body: "",
                    deliveryState: .streaming, createdAt: timestamp, updatedAt: timestamp))
            }
        }

        // Execution-style turns mark the task working so the UI reflects it.
        if wakeReason == nil || wakeReason == "assigned" || wakeReason == "resumed"
            || wakeReason == "changes_requested" {
            _ = attempt("markWorking") {
                try repo.db.transaction {
                    if let subtask, subtask.state == .claimed {
                        try repo.updateSubtaskState(subtask.id, .working, at: timestamp)
                    }
                    if let current = try repo.task(task.id),
                       current.state.canTransition(to: .working) {
                        try transition(task.id, from: current.state, to: .working,
                                       at: timestamp)
                    }
                }
            }
            publishCommitted()
        }

        // Context: only committed messages after the participant's consumed
        // cursor (§8.5), bounded to the last 60. Streaming placeholders are
        // excluded from packets and from cursor advancement (F1).
        let lastRead: Int64 = attempt("participantCursor", {
            try repo.participant(task.id, engineer)?.lastReadSeq ?? 0
        }) ?? 0
        var recent: [Message] = (attempt("recentMessages",
            { try repo.messages(task.id, afterSeq: lastRead) }) ?? [])
            .filter { $0.deliveryState == .committed }
        var truncatedNote: String?
        if recent.count > 60 {
            truncatedNote = "\(recent.count - 60) older messages omitted"
            recent = Array(recent.suffix(60))
        }
        let maxSeq = recent.map(\.seq).max() ?? lastRead

        var body = ""
        var usage = UsageSample(source: "unknown")
        var failedReason: String?
        var sawCompletion = false
        // A pending stop request (pause/cancel/quota-stop) asks the turn to
        // end with a checkpoint — only while a turn is running (§6.3).
        let wantsCheckpoint = checkpointRequested.remove(engineer) != nil
        let context = TurnContext(task: task, subtask: subtask,
                                  recentMessages: recent,
                                  wakeReason: wakeReason,
                                  wakeDetail: await wakeDetail(
                                      for: wakeReason, task: task,
                                      engineer: engineer, subtask: subtask),
                                  truncatedNote: truncatedNote,
                                  checkpointRequest: wantsCheckpoint)
        packetInspector?(engineer, context.packetText(for: engineer))
        let turnID = newID("turn")
        runningTurnRefs[turnKey] = (adapter, ref, turnID)
        defer { runningTurnRefs.removeValue(forKey: turnKey) }

        // T05: durable turn row + 5-minute lease + 60 s heartbeat + §10
        // reservation while the turn streams.
        let turnRowID = newID("turnrow")
        runningTurnRowIDs[turnKey] = turnRowID
        defer { runningTurnRowIDs.removeValue(forKey: turnKey) }
        _ = attempt("insertTurn") {
            try repo.insertTurn(Turn(
                id: turnRowID, taskID: task.id, subtaskID: subtask?.id,
                engineerID: engineer, generation: subtask?.generation,
                state: "running", startedAt: timestamp,
                nativeSessionID: ref.nativeSessionID, requestIDs: [turnID]))
        }
        if let subtask, subtask.ownerID == engineer {
            _ = attempt("leaseStart") {
                try repo.renewSubtaskLease(subtask.id, owner: engineer,
                    generation: subtask.generation,
                    leaseExpiresAt: timestamp.addingTimeInterval(300), at: timestamp)
            }
        }
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let subtask else { return }
                await self.renewLeaseHeartbeat(subtask: subtask, engineer: engineer)
            }
        }
        defer { heartbeat.cancel() }
        let reservationID = holdReservation(for: engineer, taskID: task.id, at: timestamp)

        let stream = adapter.sendTurn(ref: ref, turnID: turnID, context: context,
                                      deadline: timestamp.addingTimeInterval(300))
        var firstEventMarked = false
        do {
            for try await event in stream {
                if !firstEventMarked {
                    firstEventMarked = true
                    _ = attempt("turnFirstEvent") {
                        try repo.markTurnFirstEvent(turnRowID, at: now())
                    }
                }
                switch event {
                case .messageDelta(let delta):
                    body += delta
                    _ = attempt("updateMessageBody",
                                { try repo.updateMessageBody(messageID, body: body, at: now()) })
                    publishTransient(taskID: task.id, type: "message.delta",
                                     payload: #"{"message_id":""# + messageID.rawValue
                                         + #"","task_id":""# + task.id.rawValue + #""}"#)
                case .usageSample(let input, let output, let cacheRead, let cacheWrite, let source):
                    usage = UsageSample(input: input, output: output, cacheRead: cacheRead,
                                        cacheWrite: cacheWrite, source: source)
                    _ = attempt("usageSample") {
                        try repo.insertUsageSample(taskID: task.id, engineerID: engineer,
                                                   provider: engineer.rawValue,
                                                   model: bound.modelSelection,
                                                   nativeSessionID: ref.nativeSessionID,
                                                   turnID: turnID, sample: usage, at: now())
                    }
                case .uncertain(let note):
                    _ = attempt("uncertainNote") {
                        let t = now()
                        try repo.insertMessage(Message(
                            id: MessageID(newID("msg")), taskID: task.id,
                            seq: try repo.nextMessageSeq(task.id), author: .system,
                            kind: .systemEvent, body: note,
                            deliveryState: .committed, createdAt: t, updatedAt: t))
                    }
                case .turnCompleted:
                    sawCompletion = true
                default:
                    break
                }
            }
        } catch {
            failedReason = error.localizedDescription
            body += "\n\n[turn failed: \(failedReason!); marked uncertain]"
        }

        // Commit the turn outcome. A failed stream never reports completion.
        // Consumed cursor advances only on a completed turn (§8.5).
        let endTime = now()
        let cancelled = attempt("taskCancelState", {
            try repo.task(task.id)?.cancelRequestedAt != nil
        }) ?? false
        let turnFinal = cancelled ? "cancelled"
            : (failedReason != nil ? "uncertain" : "completed")
        // A cancel that already set cancelled/uncertain wins over "completed".
        if let existing: Turn = attempt("turnRow", { try repo.turn(turnRowID) }) ?? nil,
           existing.state == "running" || existing.state == "cancel_requested" {
            _ = attempt("turnFinal") {
                try repo.updateTurnState(turnRowID, turnFinal, at: endTime)
            }
        }
        reconcileReservation(reservationID, usage: usage, at: endTime)
        _ = attempt("commitTurn") {
            try repo.db.transaction {
                try repo.updateMessageBody(messageID, body: body, at: endTime)
                // F1: the placeholder takes its real seq now, so tool-posted
                // messages from the same turn keep their earlier seqs.
                try repo.reassignMessageSeq(messageID,
                                            seq: try repo.nextMessageSeq(task.id),
                                            at: endTime)
                try repo.updateMessageDelivery(messageID, .committed, at: endTime)
                try repo.insertOutbox(taskID: task.id, eventType: "message.committed",
                                      payload: #"{"message_id":""# + messageID.rawValue
                                          + #"","task_id":""# + task.id.rawValue + #""}"#,
                                      deliveryState: "pending", at: endTime)
                if failedReason == nil, sawCompletion {
                    try repo.setLastReadSeq(task.id, engineer, seq: maxSeq, at: endTime)
                }
                let latest = try repo.task(task.id)
                if let latest, latest.cancelRequestedAt != nil,
                   latest.state != .cancelled {
                    // A cancellation was requested while this turn ran.
                    if latest.state.canTransition(to: .cancelled) {
                        try transition(task.id, from: latest.state, to: .cancelled,
                                       at: endTime)
                    } else {
                        try repo.updateTaskState(task.id, .cancelled, at: endTime)
                    }
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: task.id,
                        seq: try repo.nextMessageSeq(task.id), author: .system,
                        kind: .systemEvent, body: "Cancellation completed",
                        deliveryState: .committed, createdAt: endTime, updatedAt: endTime))
                } else if let failedReason {
                    if wakeReason == nil {
                        if let subtask {
                            try repo.updateSubtaskState(subtask.id, .blocked, at: endTime)
                        }
                        if let current = try repo.task(task.id), current.state == .working {
                            try transition(task.id, from: .working, to: .blocked, at: endTime)
                        }
                        try repo.insertMessage(Message(
                            id: MessageID(newID("msg")), taskID: task.id,
                            seq: try repo.nextMessageSeq(task.id), author: .system,
                            kind: .systemEvent,
                            body: "Turn failed: \(failedReason). Result uncertain; "
                                + "awaiting reconciliation.",
                            deliveryState: .committed, createdAt: endTime, updatedAt: endTime))
                        let payload = try JSONEncoder().encode(StateChangedPayload(
                            task_id: task.id.rawValue, state: "blocked", usage: usage))
                        try repo.insertOutbox(taskID: task.id, eventType: "task.state_changed",
                                              payload: String(decoding: payload, as: UTF8.self),
                                              deliveryState: "pending", at: endTime)
                    }
                } else if wakeReason == nil {
                    if let subtask {
                        try repo.updateSubtaskState(subtask.id, .review, at: endTime)
                    }
                    if let current = try repo.task(task.id),
                       current.state.canTransition(to: .verifying) {
                        try transition(task.id, from: current.state, to: .verifying,
                                       at: endTime)
                    }
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: task.id,
                        seq: try repo.nextMessageSeq(task.id), author: .system,
                        kind: .systemEvent,
                        body: "Owner reported complete; verification pending",
                        deliveryState: .committed, createdAt: endTime, updatedAt: endTime))
                    let payload = try JSONEncoder().encode(StateChangedPayload(
                        task_id: task.id.rawValue, state: "verifying", usage: usage))
                    try repo.insertOutbox(taskID: task.id, eventType: "task.state_changed",
                                          payload: String(decoding: payload, as: UTF8.self),
                                          deliveryState: "pending", at: endTime)
                }
            }
        }
        publishCommitted()
    }

    // MARK: - Phase 3: collaboration policy (§5.1, §5.3, §5.5, §8.2)

    private func loadTask(_ taskID: TaskID) throws -> WorkshopTask {
        guard let task = try repo.task(taskID) else {
            throw WorkshopError.taskNotFound(taskID)
        }
        return task
    }

    private func requireUser(_ principal: Principal, _ action: String) throws {
        guard principal == .user else {
            throw WorkshopError.userAuthorityRequired(action)
        }
    }

    /// T07: on substantial tasks implementation tools need approval covering
    /// the current report revision (T08 invalidates older approvals).
    private func requireImplementationApproval(_ task: WorkshopTask) throws {
        if task.phase == .researchProposal && !task.hasCurrentApproval {
            throw WorkshopError.approvalRequired(task.id)
        }
    }

    /// Extra packet payload for special wakeup reasons (spec §G + Phase 3).
    private func wakeDetail(for reason: String?, task: WorkshopTask,
                            engineer: EngineerID, subtask: Subtask?) async -> String? {
        guard let reason else { return nil }
        let head = reason.split(separator: ":").first.map(String.init) ?? reason
        switch head {
        case "verify_result":
            let messageID = reason.split(separator: ":").dropFirst().first
                .map(String.init) ?? ""
            return "Result message to verify: \(messageID). Read it via "
                + "workshop_read_messages and inspect artifacts via workshop_get_task."
        case "allocate":
            var lines = ["Ready subtasks (assign each via workshop_assign_subtask):"]
            let subs = (try? repo.subtasks(task.id)) ?? []
            let ownership = latestReportOwnership(task.id)
            for sub in subs where sub.state == .ready || sub.state == .claimed {
                let proposed = ownership[sub.title]?.stringValue ?? "none"
                let deps = sub.dependencies.joined(separator: ", ")
                lines.append("- \(sub.id.rawValue) \"\(sub.title)\" risk=\(sub.risk) "
                    + "proposed_owner=\(proposed) deps=[\(deps)] state=\(sub.state.rawValue)")
            }
            lines.append("Engineer health:")
            for participant in ((try? repo.participants(task.id)) ?? []).map(\.engineerID) {
                if let adapter = adapters[participant] {
                    let probe = await adapter.probe()
                    lines.append("- \(participant.rawValue): \(probe.health.label) "
                        + "(\(probe.health.detail))")
                } else {
                    lines.append("- \(participant.rawValue): Unavailable (no adapter)")
                }
            }
            return lines.joined(separator: "\n")
        case "dispute":
            let disputes = ((try? repo.decisions(task.id)) ?? [])
                .filter { $0.kind == "dispute" }
            if let last = disputes.last {
                return "Dispute from \(last.author): \(last.body)"
            }
            return nil
        case "revise_report":
            let changes = ((try? repo.decisions(task.id)) ?? [])
                .filter { $0.kind == "request_changes" }
            if let last = changes.last {
                return "Requested changes: \(last.body)"
            }
            return nil
        case "resume_from_checkpoint":
            // The checkpoint JSON rides in the packet (§6.3); the engineer
            // must re-read artifacts before editing.
            if let json = pendingCheckpointDetail.removeValue(forKey: engineer) {
                return "Checkpoint JSON:\n" + json
            }
            return nil
        default:
            return nil
        }
    }

    /// proposed_owner per subtask_title from the latest report (or the
    /// approved proposal when the user overrode with scope "proposal:<id>").
    private func latestReportOwnership(_ taskID: TaskID) -> [String: JSONValue] {
        guard let report = try? repo.latestReport(taskID),
              let content = try? JSONDecoder().decode(JSONValue.self,
                                                      from: Data(report.content.utf8)),
              let items = content["proposed_ownership"]?.arrayValue else { return [:] }
        var map: [String: JSONValue] = [:]
        for item in items {
            if let title = item["subtask_title"]?.stringValue {
                map[title] = item["proposed_owner"]
            }
        }
        return map
    }

    // MARK: Deadlines

    private func scheduleResearchDeadline(_ taskID: TaskID) {
        guard researchDeadline > 0 else { return }
        let key = "research:" + taskID.rawValue
        policyTimers[key]?.cancel()
        let deadline = researchDeadline
        policyTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            _ = try? await self?.publishProposals(taskID)
        }
    }

    private func scheduleReviewDeadline(_ taskID: TaskID) {
        guard reviewDeadline > 0 else { return }
        let key = "review:" + taskID.rawValue
        policyTimers[key]?.cancel()
        let deadline = reviewDeadline
        policyTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            await self?.requestConsolidation(taskID)
        }
    }

    /// Wake Devin to consolidate once, while the task is reviewing proposals.
    private func requestConsolidation(_ taskID: TaskID) {
        guard let task = try? repo.task(taskID),
              task.state == .reviewingProposal else { return }
        let already = ((try? repo.wakeups(taskID)) ?? []).contains {
            $0.engineerID == .devin && $0.reason == "consolidate"
        }
        guard !already else { return }
        _ = attempt("consolidateWakeup") {
            try repo.insertWakeup(taskID: taskID, engineerID: .devin,
                                  reason: "consolidate", triggerSeq: nil, at: now())
        }
        scheduleWakeupCoalescer()
    }

    // MARK: Proposals (T12)

    /// workshop_submit_proposal: one independent proposal per participant,
    /// stored as a private draft until publication.
    public func toolSubmitProposal(taskID: TaskID, content: JSONValue,
                                   principal: Principal) async throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("submit_proposal requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        let task = try loadTask(taskID)
        guard task.phase == .researchProposal else {
            throw WorkshopError.invalidRequest("task is not a research task")
        }
        guard task.state == .researching || task.state == .reviewingProposal else {
            throw WorkshopError.invalidRequest(
                "proposals are only accepted while researching/reviewing (state: "
                + task.state.rawValue + ")")
        }
        var stripped = content
        if case .object(var obj) = stripped {
            obj.removeValue(forKey: "task_id")
            stripped = .object(obj)
        }
        let data = try JSONEncoder().encode(stripped)
        let timestamp = now()
        var result: Proposal
        if let existing = try repo.proposalBy(taskID: taskID, author: engineer) {
            var updated = existing
            updated.revision += 1
            updated.content = String(decoding: data, as: UTF8.self)
            updated.updatedAt = timestamp
            try repo.upsertProposal(updated)
            result = updated
        } else {
            let proposal = Proposal(id: newID("prop"), taskID: taskID, author: engineer,
                                    content: String(decoding: data, as: UTF8.self),
                                    createdAt: timestamp, updatedAt: timestamp)
            try repo.upsertProposal(proposal)
            result = proposal
        }
        // Publish early once every available participant has drafted.
        if task.state == .researching {
            let participants = try repo.participants(taskID).map(\.engineerID)
            var allDrafted = !participants.isEmpty
            for participant in participants {
                guard let adapter = adapters[participant],
                      await adapter.probe().health.kind == .available else { continue }
                if try repo.proposalBy(taskID: taskID, author: participant) == nil {
                    allDrafted = false
                }
            }
            if allDrafted { try await publishProposals(taskID) }
        }
        return .object(["proposal_id": .string(result.id),
                        "revision": .number(Double(result.revision)),
                        "visibility": .string(result.visibility)])
    }

    /// workshop_read_proposals: published proposals plus the caller's own
    /// draft; other engineers' drafts are invisible (T12).
    public func toolReadProposals(taskID: TaskID, principal: Principal) throws -> [Proposal] {
        let all = try repo.proposals(taskID)
        return all.filter {
            $0.visibility == "published" || $0.author == principal.engineerID
        }
    }

    /// All proposals for the UI/user (drafts included — the user sees counts).
    public func listProposals(_ taskID: TaskID) throws -> [Proposal] {
        try repo.proposals(taskID)
    }

    public func listReports(_ taskID: TaskID) throws -> [Report] {
        try repo.reports(taskID)
    }

    public func listDecisions(_ taskID: TaskID) throws -> [Decision] {
        try repo.decisions(taskID)
    }

    /// Publish all drafts together: visibility flips atomically, the task
    /// moves to ReviewingProposal, and every participant gets a cross_review
    /// wakeup. Missing participants are recorded in the system event.
    public func publishProposals(_ taskID: TaskID) async throws {
        let task = try loadTask(taskID)
        guard task.phase == .researchProposal, task.state == .researching else { return }
        let timestamp = now()
        let proposals = try repo.proposals(taskID)
        let authors = proposals.map(\.author.rawValue).sorted()
        let participants = try repo.participants(taskID).map(\.engineerID)
        let missing = participants.filter { p in
            !proposals.contains { $0.author == p }
        }.map(\.rawValue).sorted()
        try repo.db.transaction {
            try repo.publishAllProposals(taskID, at: timestamp)
            try transition(taskID, from: .researching, to: .reviewingProposal,
                           at: timestamp)
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "Proposals published by: \(authors.joined(separator: ", "))"
                    + (missing.isEmpty ? "" : "; missing: \(missing.joined(separator: ", "))"),
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
            for engineer in participants {
                try repo.insertWakeup(taskID: taskID, engineerID: engineer,
                                      reason: "cross_review", triggerSeq: nil,
                                      at: timestamp)
            }
            try repo.insertOutbox(taskID: taskID, eventType: "task.state_changed",
                                  payload: #"{"task_id":""# + taskID.rawValue
                                      + #"","state":"reviewing_proposal"}"#,
                                  deliveryState: "pending", at: timestamp)
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        scheduleReviewDeadline(taskID)
    }

    // MARK: Reviews (cross-review + proportional verification, §5.5)

    /// workshop_submit_review: stored as a kind=review message carrying a
    /// structured payload; drives consolidation and verification outcomes.
    public func toolSubmitReview(taskID: TaskID, proposalID: String, severity: String,
                                 disposition: String, body: String, evidence: String?,
                                 principal: Principal) async throws -> Message {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("submit_review requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        guard ["low", "medium", "high"].contains(severity) else {
            throw WorkshopError.invalidRequest("severity must be low|medium|high")
        }
        guard ["agree", "disagree", "needs_changes"].contains(disposition) else {
            throw WorkshopError.invalidRequest(
                "disposition must be agree|disagree|needs_changes")
        }
        var structured: [String: JSONValue] = [
            "type": .string("review"),
            "proposal_id": .string(proposalID),
            "severity": .string(severity),
            "disposition": .string(disposition),
        ]
        if let evidence { structured["evidence"] = .string(evidence) }
        let structuredText = String(
            decoding: try JSONEncoder().encode(JSONValue.object(structured)),
            as: UTF8.self)
        let message = try postMessage(taskID: taskID, body: body, principal: principal,
                                      kind: .review, structured: structuredText)

        if try repo.proposal(proposalID) != nil {
            // Proposal review: consolidate once every available participant
            // has submitted at least one review (§5.3).
            let participants = try repo.participants(taskID).map(\.engineerID)
            let proposalIDs = Set(try repo.proposals(taskID).map(\.id))
            var reviewedBy = Set<EngineerID>()
            for m in try repo.messages(taskID) where m.kind == .review {
                guard let author = m.author.engineerID,
                      let s = m.structured,
                      let value = try? JSONDecoder().decode(JSONValue.self,
                                                            from: Data(s.utf8)),
                      value["type"]?.stringValue == "review",
                      let pid = value["proposal_id"]?.stringValue,
                      proposalIDs.contains(pid) else { continue }
                reviewedBy.insert(author)
            }
            var allReviewed = !participants.isEmpty
            for participant in participants {
                guard let adapter = adapters[participant],
                      await adapter.probe().health.kind == .available else { continue }
                if !reviewedBy.contains(participant) { allReviewed = false }
            }
            if allReviewed { requestConsolidation(taskID) }
        } else if let resultMessage = try repo.message(MessageID(proposalID)),
                  let s = resultMessage.structured,
                  let value = try? JSONDecoder().decode(JSONValue.self,
                                                        from: Data(s.utf8)),
                  let subtaskRaw = value["subtask_id"]?.stringValue,
                  let subtask = try repo.subtask(SubtaskID(subtaskRaw)),
                  subtask.taskID == taskID {
            // Verification review of a report_result message (§5.5).
            let timestamp = now()
            try repo.db.transaction {
                if disposition == "agree" {
                    try repo.updateSubtaskState(subtask.id, .done, at: timestamp)
                    try repo.updateSubtaskVerification(subtask.id, "passed",
                                                     at: timestamp)
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: taskID,
                        seq: try repo.nextMessageSeq(taskID), author: .system,
                        kind: .systemEvent,
                        body: "Verification passed for \"\(subtask.title)\"",
                        deliveryState: .committed, createdAt: timestamp,
                        updatedAt: timestamp))
                } else {
                    try repo.updateSubtaskState(subtask.id, .working, at: timestamp)
                    try repo.updateSubtaskVerification(subtask.id, "changes_requested",
                                                     at: timestamp)
                    if let current = try repo.task(taskID),
                       current.state == .verifying {
                        try transition(taskID, from: .verifying, to: .working,
                                       at: timestamp)
                    }
                    if let owner = subtask.ownerID {
                        try repo.insertWakeup(taskID: taskID, engineerID: owner,
                                              reason: "changes_requested",
                                              triggerSeq: message.seq, at: timestamp)
                    }
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: taskID,
                        seq: try repo.nextMessageSeq(taskID), author: .system,
                        kind: .systemEvent,
                        body: "Verification requested changes on "
                            + "\"\(subtask.title)\"",
                        deliveryState: .committed, createdAt: timestamp,
                        updatedAt: timestamp))
                }
            }
            publishCommitted()
            scheduleWakeupCoalescer()
        }
        return message
    }

    // MARK: Consolidated report (§5.3)

    /// workshop_submit_report: Devin (or the user) writes revision N of the
    /// consolidated report. A later revision invalidates any approval (T08).
    public func toolSubmitReport(taskID: TaskID, content: JSONValue,
                                 principal: Principal) async throws -> JSONValue {
        guard principal == .user || principal == .engineer(.devin) else {
            throw WorkshopError.userAuthorityRequired(
                "the consolidated report is Devin Fusion's responsibility")
        }
        if let engineer = principal.engineerID {
            try requireParticipant(engineer, taskID: taskID)
        }
        let task = try loadTask(taskID)
        var stripped = content
        if case .object(var obj) = stripped {
            obj.removeValue(forKey: "task_id")
            stripped = .object(obj)
        }
        let data = try JSONEncoder().encode(stripped)
        let timestamp = now()
        let revision = ((try repo.latestReport(taskID))?.revision ?? 0) + 1
        let report = Report(id: newID("rep"), taskID: taskID, revision: revision,
                            author: principal.kind == "engineer" ? "devin" : "user",
                            content: String(decoding: data, as: UTF8.self),
                            createdAt: timestamp)
        var invalidatedFrom: Int?
        try repo.db.transaction {
            try repo.insertReport(report)
            try repo.updateTaskRevisions(taskID, reportRevision: .some(revision),
                                         at: timestamp)
            // T08: a new revision revokes the older approval's authority.
            if let approved = task.approvalRevision, approved != revision {
                try repo.updateTaskRevisions(taskID, approvalRevision: .some(nil),
                                             at: timestamp)
                invalidatedFrom = approved
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "Report revised to r\(revision); prior approval (r\(approved)) "
                        + "no longer authorizes new work",
                    deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
            }
            if task.state == .reviewingProposal {
                try transition(taskID, from: .reviewingProposal,
                               to: .awaitingArchitectureApproval, at: timestamp)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID),
                author: principal, kind: .proposal,
                body: "Consolidated report r\(revision)",
                deliveryState: .committed,
                structured: #"{"type":"report","revision":\#(revision),"report_id":""#
                    + report.id + #""}"#,
                createdAt: timestamp, updatedAt: timestamp))
            try repo.insertOutbox(taskID: taskID, eventType: "task.state_changed",
                                  payload: #"{"task_id":""# + taskID.rawValue
                                      + #"","report_revision":\#(revision)}"#,
                                  deliveryState: "pending", at: timestamp)
        }
        _ = invalidatedFrom
        publishCommitted()
        return .object(["report_id": .string(report.id),
                        "revision": .number(Double(revision))])
    }

    // MARK: User authority: approval / changes / alternative

    /// Shared approval path (approveArchitecture / chooseAlternative /
    /// proposal override). User principal only.
    private func approve(taskID: TaskID, reportRevision: Int, scope: String?,
                         kind: String, principal: Principal) async throws {
        try requireUser(principal, "approve architecture")
        let task = try loadTask(taskID)
        guard task.phase == .researchProposal else {
            throw WorkshopError.invalidRequest("task is not a research task")
        }
        let current = task.reportRevision ?? 0
        guard reportRevision == current else {
            throw WorkshopError.staleRevision(expected: reportRevision,
                                            actual: task.reportRevision)
        }
        // Resolve the approved content: latest report, or a published proposal
        // when the user overrides via scope "proposal:<id>" (§5.3).
        var contentJSON: JSONValue?
        if let scope, scope.hasPrefix("proposal:") {
            let proposalID = String(scope.dropFirst("proposal:".count))
            guard let proposal = try repo.proposal(proposalID),
                  proposal.taskID == taskID,
                  proposal.visibility == "published" else {
                throw WorkshopError.invalidRequest(
                    "scope proposal is not a published proposal on this task")
            }
            contentJSON = try? JSONDecoder().decode(JSONValue.self,
                                                    from: Data(proposal.content.utf8))
        } else if let report = try repo.latestReport(taskID) {
            contentJSON = try? JSONDecoder().decode(JSONValue.self,
                                                    from: Data(report.content.utf8))
        }
        let timestamp = now()
        let firstApproval = task.approvalRevision == nil
        try repo.db.transaction {
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: kind,
                revision: reportRevision, scope: scope, author: "user",
                body: scope ?? "approved", createdAt: timestamp))
            try repo.updateTaskRevisions(taskID,
                                         approvalRevision: .some(reportRevision),
                                         at: timestamp)
            var state = task.state
            if state == .reviewingProposal {
                try transition(taskID, from: state,
                               to: .awaitingArchitectureApproval, at: timestamp)
                state = .awaitingArchitectureApproval
            }
            if state == .awaitingArchitectureApproval {
                try transition(taskID, from: state, to: .ready, at: timestamp)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "Architecture approved (r\(reportRevision)"
                    + (scope.map { ", scope \($0)" } ?? "") + ")",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
            if firstApproval, let contentJSON {
                try createSubtasks(from: contentJSON, taskID: taskID, at: timestamp)
            }
        }
        publishCommitted()
        // Wake the allocation arbiter.
        if try repo.participant(taskID, .devin) != nil {
            _ = try repo.insertWakeup(taskID: taskID, engineerID: .devin,
                                      reason: "allocate", triggerSeq: nil,
                                      at: now())
            scheduleWakeupCoalescer()
        } else {
            _ = attempt("allocateUnavailable") {
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "Allocation waits for Devin Fusion, who is not a "
                        + "participant of this task",
                    deliveryState: .committed, createdAt: now(), updatedAt: now()))
            }
            publishCommitted()
        }
    }

    /// Create subtasks from a report/proposal's proposed_ownership array.
    /// Dependencies are title references resolved in a second pass.
    private func createSubtasks(from content: JSONValue, taskID: TaskID,
                                at timestamp: Date) throws {
        guard let items = content["proposed_ownership"]?.arrayValue else { return }
        var idByTitle: [String: SubtaskID] = [:]
        for item in items {
            guard let title = item["subtask_title"]?.stringValue else { continue }
            let id = SubtaskID(newID("sub"))
            idByTitle[title] = id
            let acceptance = item["acceptance_criteria"]?.arrayValue?
                .compactMap { $0.stringValue }
                ?? item["acceptance_criteria"]?.stringValue.map { [$0] } ?? []
            try repo.insertSubtask(Subtask(
                id: id, taskID: taskID, title: title, acceptance: acceptance,
                risk: item["risk"]?.stringValue ?? "normal",
                createdAt: timestamp, updatedAt: timestamp))
        }
        for item in items {
            guard let title = item["subtask_title"]?.stringValue,
                  let id = idByTitle[title],
                  let deps = item["depends_on"]?.arrayValue else { continue }
            let depIDs = deps.compactMap { $0.stringValue }
                .compactMap { idByTitle[$0]?.rawValue }
            guard !depIDs.isEmpty else { continue }
            try repo.db.execute(
                "UPDATE subtasks SET dependencies=? WHERE id=?",
                [.text(String(decoding: try JSONEncoder().encode(depIDs),
                              as: UTF8.self)), .text(id.rawValue)])
        }
    }

    public func approveArchitecture(taskID: TaskID, reportRevision: Int, scope: String?,
                                    principal: Principal) async throws {
        try await approve(taskID: taskID, reportRevision: reportRevision,
                          scope: scope, kind: "approval", principal: principal)
    }

    public func requestChanges(taskID: TaskID, reportRevision: Int, comment: String,
                               principal: Principal) async throws {
        try requireUser(principal, "request changes")
        let task = try loadTask(taskID)
        guard reportRevision == task.reportRevision ?? 0 else {
            throw WorkshopError.staleRevision(expected: reportRevision,
                                            actual: task.reportRevision)
        }
        let timestamp = now()
        try repo.db.transaction {
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: "request_changes",
                revision: reportRevision, author: "user", body: comment,
                createdAt: timestamp))
            if task.state == .awaitingArchitectureApproval {
                try transition(taskID, from: .awaitingArchitectureApproval,
                               to: .reviewingProposal, at: timestamp)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "Changes requested on report r\(reportRevision): \(comment)",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
        }
        publishCommitted()
        if try repo.participant(taskID, .devin) != nil {
            _ = try repo.insertWakeup(taskID: taskID, engineerID: .devin,
                                      reason: "revise_report", triggerSeq: nil,
                                      at: now())
            scheduleWakeupCoalescer()
        }
    }

    public func chooseAlternative(taskID: TaskID, reportRevision: Int,
                                  alternativeIndex: Int,
                                  principal: Principal) async throws {
        try await approve(taskID: taskID, reportRevision: reportRevision,
                          scope: "alternative:\(alternativeIndex)",
                          kind: "choose_alternative", principal: principal)
    }

    // MARK: Allocation (§5.3)

    /// workshop_assign_subtask: Devin (arbiter) or the user. CAS on generation;
    /// refuses when dependencies are unfinished.
    public func toolAssignSubtask(taskID: TaskID, subtaskID: SubtaskID,
                                  owner: EngineerID, rationale: String,
                                  expectedGeneration: Int?,
                                  principal: Principal) async throws -> JSONValue {
        guard principal == .user || principal == .engineer(.devin) else {
            throw WorkshopError.userAuthorityRequired(
                "assignment authority belongs to the user or Devin Fusion")
        }
        if let engineer = principal.engineerID {
            try requireParticipant(engineer, taskID: taskID)
        }
        let task = try loadTask(taskID)
        try requireImplementationApproval(task)
        try requireParticipant(owner, taskID: taskID)
        guard let subtask = try repo.subtask(subtaskID), subtask.taskID == taskID else {
            throw WorkshopError.invalidRequest("subtask not found on task")
        }
        try requireDependenciesDone(subtask)
        let expected = expectedGeneration ?? subtask.generation
        let timestamp = now()
        var assigned = false
        try repo.db.transaction {
            assigned = try repo.assignSubtask(
                subtaskID, owner: owner, expectedGeneration: expected,
                leaseExpiresAt: timestamp.addingTimeInterval(300), at: timestamp)
            guard assigned else { return }
            let proposed = latestReportOwnership(taskID)[subtask.title]?.stringValue
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: "allocation",
                author: principal.kind == "user" ? "user" : "devin",
                body: rationale, relatedID: subtaskID.rawValue, createdAt: timestamp))
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .assignment,
                body: "\(subtask.title) assigned to \(owner.displayName)",
                deliveryState: .committed,
                structured: String(decoding: try JSONEncoder().encode(JSONValue.object([
                    "type": .string("assignment"),
                    "subtask_id": .string(subtaskID.rawValue),
                    "title": .string(subtask.title),
                    "proposed_owner": proposed.map { JSONValue.string($0) } ?? .null,
                    "owner": .string(owner.rawValue),
                    "rationale": .string(rationale),
                ])), as: UTF8.self),
                createdAt: timestamp, updatedAt: timestamp))
            try repo.insertWakeup(taskID: taskID, engineerID: owner,
                                  reason: "assigned", triggerSeq: nil, at: timestamp)
        }
        guard assigned else {
            throw WorkshopError.invalidRequest(
                "subtask already owned or stale generation")
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        return .object(["assigned": .bool(true),
                        "generation": .number(Double(expected + 1))])
    }

    private func requireDependenciesDone(_ subtask: Subtask) throws {
        for depID in subtask.dependencies {
            guard let dep = try repo.subtask(SubtaskID(depID)),
                  dep.state == .done else {
                throw WorkshopError.blockedByDependency(subtask.id)
            }
        }
    }

    /// workshop_claim_subtask: a participant claims an unowned, unblocked
    /// subtask (small tasks, or approved substantial tasks).
    public func toolClaimSubtask(taskID: TaskID, subtaskID: SubtaskID,
                                 principal: Principal) async throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("claim_subtask requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        let task = try loadTask(taskID)
        try requireImplementationApproval(task)
        guard let adapter = adapters[engineer],
              await adapter.probe().health.kind == .available else {
            throw WorkshopError.adapterUnavailable(engineer)
        }
        guard let subtask = try repo.subtask(subtaskID), subtask.taskID == taskID else {
            throw WorkshopError.invalidRequest("subtask not found on task")
        }
        try requireDependenciesDone(subtask)
        let timestamp = now()
        var claimed = false
        try repo.db.transaction {
            claimed = try repo.claimSubtask(
                subtaskID, owner: engineer,
                expectedGeneration: subtask.generation,
                leaseExpiresAt: timestamp.addingTimeInterval(300), at: timestamp)
            guard claimed else { return }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "\(engineer.displayName) claimed \(subtask.title) "
                    + "(generation \(subtask.generation + 1))",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
            try repo.insertWakeup(taskID: taskID, engineerID: engineer,
                                  reason: "assigned", triggerSeq: nil, at: timestamp)
        }
        guard claimed else {
            throw WorkshopError.invalidRequest("subtask already owned")
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        return .object(["claimed": .bool(true)])
    }

    /// workshop_propose_subtask: a participant proposes a new subtask; it is
    /// created ready with a structured proposal card.
    public func toolProposeSubtask(taskID: TaskID, title: String,
                                   acceptanceCriteria: [String],
                                   proposedOwner: EngineerID?, risk: String?,
                                   dependsOn: [String],
                                   principal: Principal) async throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest(
                "propose_subtask requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        let task = try loadTask(taskID)
        try requireImplementationApproval(task)
        let timestamp = now()
        let subtaskID = SubtaskID(newID("sub"))
        let existing = try repo.subtasks(taskID)
        let depIDs = dependsOn.compactMap { name in
            existing.first { $0.title == name || $0.id.rawValue == name }?.id.rawValue
        }
        try repo.db.transaction {
            try repo.insertSubtask(Subtask(
                id: subtaskID, taskID: taskID, title: title,
                acceptance: acceptanceCriteria, dependencies: depIDs,
                risk: risk ?? "normal",
                createdAt: timestamp, updatedAt: timestamp))
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: principal,
                kind: .proposal, body: "Proposed subtask: \(title)",
                deliveryState: .committed,
                structured: String(decoding: try JSONEncoder().encode(JSONValue.object([
                    "type": .string("subtask_proposal"),
                    "subtask_id": .string(subtaskID.rawValue),
                    "title": .string(title),
                    "proposed_owner": proposedOwner
                        .map { JSONValue.string($0.rawValue) } ?? .null,
                    "risk": .string(risk ?? "normal"),
                    "depends_on": .array(depIDs.map { .string($0) }),
                ])), as: UTF8.self),
                createdAt: timestamp, updatedAt: timestamp))
        }
        publishCommitted()
        return .object(["subtask_id": .string(subtaskID.rawValue)])
    }

    /// workshop_dispute_assignment: an engineer disputes an allocation; the
    /// dispute is recorded and Devin is woken to resolve it.
    public func toolDisputeAssignment(taskID: TaskID, subtaskID: SubtaskID,
                                      body: String,
                                      principal: Principal) async throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest(
                "dispute_assignment requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        _ = try loadTask(taskID)
        let timestamp = now()
        try repo.db.transaction {
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: "dispute",
                author: engineer.rawValue, body: body,
                relatedID: subtaskID.rawValue, createdAt: timestamp))
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "\(engineer.displayName) disputed the assignment of "
                    + subtaskID.rawValue + ": " + body,
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
            if try repo.participant(taskID, .devin) != nil {
                try repo.insertWakeup(taskID: taskID, engineerID: .devin,
                                      reason: "dispute", triggerSeq: nil,
                                      at: timestamp)
            }
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        return .object(["recorded": .bool(true)])
    }

    /// workshop_escalate_task: an engineer pauses the task and asks the user
    /// to convert it to research or resume it.
    public func toolEscalateTask(taskID: TaskID, reason: String,
                                 principal: Principal) async throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("escalate_task requires an engineer principal")
        }
        try requireParticipant(engineer, taskID: taskID)
        let task = try loadTask(taskID)
        let timestamp = now()
        try repo.db.transaction {
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: "escalation",
                author: engineer.rawValue, body: reason, createdAt: timestamp))
            if task.state == .working {
                try transition(taskID, from: .working, to: .paused, at: timestamp)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "\(engineer.displayName) escalated: \(reason). "
                    + "User may convert to research or resume.",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
        }
        publishCommitted()
        return .object(["escalated": .bool(true)])
    }

    // MARK: Task actions (user principal)

    /// Pause a working task: suppress pending wakeups and cancel in-flight
    /// turns, recording requested/acknowledged system events.
    public func pauseTask(taskID: TaskID, principal: Principal) async throws {
        try requireUser(principal, "pause task")
        let task = try loadTask(taskID)
        guard task.state == .working else {
            throw WorkshopError.invalidRequest(
                "only a working task can be paused (state: \(task.state.rawValue))")
        }
        let timestamp = now()
        try repo.db.transaction {
            try transition(taskID, from: .working, to: .paused, at: timestamp)
            try repo.suppressPendingWakeups(taskID, at: timestamp)
        }
        requestCheckpointsForRunningTurns(taskID)
        await cancelRunningTurns(taskID: taskID, action: "Pause")
        publishCommitted()
    }

    /// §6.3: before pause/cancel/quota-stop, each running engineer's next
    /// packet ends with a save-checkpoint request (we do not spend a new
    /// turn just to checkpoint — the cancelled turn cannot be asked).
    private func requestCheckpointsForRunningTurns(_ taskID: TaskID) {
        for key in runningTurnRefs.keys where key.hasPrefix(taskID.rawValue + ":") {
            if let raw = key.split(separator: ":").last,
               let engineer = EngineerID(rawValue: String(raw)) {
                checkpointRequested.insert(engineer)
            }
        }
    }

    /// Resume a paused task back to Ready (or Researching for research tasks)
    /// and re-wake the owner / participants.
    public func resumeTask(taskID: TaskID, principal: Principal) async throws {
        try requireUser(principal, "resume task")
        let task = try loadTask(taskID)
        guard task.state == .paused else {
            throw WorkshopError.invalidRequest(
                "only a paused task can be resumed (state: \(task.state.rawValue))")
        }
        let timestamp = now()
        try repo.db.transaction {
            if task.phase == .researchProposal {
                try transition(taskID, from: .paused, to: .researching, at: timestamp)
                for participant in try repo.participants(taskID) {
                    try repo.insertWakeup(taskID: taskID,
                                          engineerID: participant.engineerID,
                                          reason: "research_proposal",
                                          triggerSeq: nil, at: timestamp)
                }
            } else {
                try transition(taskID, from: .paused, to: .ready, at: timestamp)
                if let sub = try repo.subtasks(taskID)
                    .first(where: { $0.ownerID != nil }),
                   let owner = sub.ownerID {
                    try repo.insertWakeup(taskID: taskID, engineerID: owner,
                                          reason: "resumed", triggerSeq: nil,
                                          at: timestamp)
                } else if let sub = try repo.subtasks(taskID)
                    .first(where: { $0.state == .ready }) {
                    try repo.insertOutbox(
                        taskID: taskID, eventType: Self.dispatchRequested,
                        payload: #"{"task_id":""# + taskID.rawValue
                            + #"","subtask_id":""# + sub.id.rawValue + #""}"#,
                        deliveryState: "pending", at: timestamp)
                }
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent, body: "Task resumed by user",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        scheduleDispatch()
    }

    /// Cancel a ready/working task. With a turn running, the request is
    /// recorded and the transition completes when the turn ends.
    public func cancelTask(taskID: TaskID, principal: Principal) async throws {
        try requireUser(principal, "cancel task")
        let task = try loadTask(taskID)
        guard task.state == .ready || task.state == .working else {
            throw WorkshopError.invalidRequest(
                "only a ready/working task can be cancelled (state: \(task.state.rawValue))")
        }
        let timestamp = now()
        let running = runningTurnRefs.keys.filter {
            $0.hasPrefix(taskID.rawValue + ":")
        }
        requestCheckpointsForRunningTurns(taskID)
        try repo.db.transaction {
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: "cancellation",
                author: "user", body: "task cancelled", createdAt: timestamp))
            try repo.suppressPendingWakeups(taskID, at: timestamp)
            if running.isEmpty {
                try transition(taskID, from: task.state, to: .cancelled, at: timestamp)
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent, body: "Cancellation completed",
                    deliveryState: .committed, createdAt: timestamp,
                    updatedAt: timestamp))
            } else {
                try repo.updateTaskRevisions(taskID,
                                             cancelRequestedAt: .some(timestamp),
                                             at: timestamp)
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent, body: "Cancellation requested",
                    deliveryState: .committed, createdAt: timestamp,
                    updatedAt: timestamp))
            }
        }
        if !running.isEmpty {
            await cancelRunningTurns(taskID: taskID, action: "Cancellation")
        }
        publishCommitted()
    }

    /// Record requested/acknowledged cancel events and call cancelTurn.
    private func cancelRunningTurns(taskID: TaskID, action: String) async {
        let keys = runningTurnRefs.keys.filter {
            $0.hasPrefix(taskID.rawValue + ":")
        }
        for key in keys {
            guard let info = runningTurnRefs[key] else { continue }
            let timestamp = now()
            _ = attempt("cancelRequestedEvent") {
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "\(action) requested; turn cancellation requested for "
                        + info.ref.engineer.displayName,
                    deliveryState: .committed, createdAt: timestamp,
                    updatedAt: timestamp))
            }
            // T23: mark the durable turn row cancel_requested before the call.
            if let rowID = runningTurnRowIDs[key] {
                _ = attempt("turnCancelRequested") {
                    try repo.updateTurnState(rowID, "cancel_requested", at: timestamp)
                }
            }
            let acknowledged = await info.adapter.cancelTurn(ref: info.ref,
                                                           turnID: info.turnID)
            let ack = now()
            if let rowID = runningTurnRowIDs[key] {
                _ = attempt("turnCancelOutcome") {
                    try repo.updateTurnState(
                        rowID, acknowledged ? "cancelled" : "uncertain", at: ack)
                }
            }
            _ = attempt("cancelAckEvent") {
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "Turn cancellation " + (acknowledged ? "acknowledged" : "uncertain")
                        + " for " + info.ref.engineer.displayName,
                    deliveryState: .committed, createdAt: ack, updatedAt: ack))
            }
        }
    }

    /// Accept a verifying task: subtasks still in review become done; the
    /// task becomes Done and an acceptance decision is recorded.
    public func acceptTask(taskID: TaskID, principal: Principal) async throws {
        try requireUser(principal, "accept task")
        let task = try loadTask(taskID)
        guard task.state == .verifying else {
            throw WorkshopError.invalidRequest(
                "only a verifying task can be accepted (state: \(task.state.rawValue))")
        }
        let timestamp = now()
        try repo.db.transaction {
            for sub in try repo.subtasks(taskID) where sub.state == .review {
                try repo.updateSubtaskState(sub.id, .done, at: timestamp)
            }
            try transition(taskID, from: .verifying, to: .done, at: timestamp)
            try repo.insertDecision(Decision(
                id: newID("dec"), taskID: taskID, kind: "acceptance",
                author: "user", body: "task accepted", createdAt: timestamp))
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent, body: "Task accepted by user",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
        }
        publishCommitted()
    }

    /// Convert a paused task (after escalation) to the research path.
    public func convertToResearch(taskID: TaskID, principal: Principal) async throws {
        try requireUser(principal, "convert to research")
        let task = try loadTask(taskID)
        guard task.state == .paused else {
            throw WorkshopError.invalidRequest(
                "only a paused task can be converted (state: \(task.state.rawValue))")
        }
        let timestamp = now()
        try repo.db.transaction {
            try repo.updateTaskPhase(taskID, .researchProposal, at: timestamp)
            try transition(taskID, from: .paused, to: .researching, at: timestamp)
            for participant in try repo.participants(taskID) {
                try repo.insertWakeup(taskID: taskID,
                                      engineerID: participant.engineerID,
                                      reason: "research_proposal",
                                      triggerSeq: nil, at: timestamp)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "Task converted to research; each participant drafts a "
                    + "proposal",
                deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
        }
        publishCommitted()
        scheduleWakeupCoalescer()
        scheduleResearchDeadline(taskID)
    }
}

/// Per-bucket capacity policy from engineers.json `budget` (§10, ADR 0012).
/// unknown ≠ 0 ≠ unlimited: a nil cap or nil usage counters produce the
/// string "unknown", never a guess and never "unlimited".
public struct CapacityPolicy: Sendable, Equatable {
    public var dailyTokenCap: Int?
    public var reservePerTurn: Int
    public var lowPct: Int
    public var criticalPct: Int
    public var hysteresisPct: Int

    public init(dailyTokenCap: Int? = nil, reservePerTurn: Int = 30_000,
                lowPct: Int = 20, criticalPct: Int = 10, hysteresisPct: Int = 5) {
        self.dailyTokenCap = dailyTokenCap
        self.reservePerTurn = reservePerTurn
        self.lowPct = lowPct
        self.criticalPct = criticalPct
        self.hysteresisPct = hysteresisPct
    }
}

/// One search result (§14.1): task + snippet for the UI list.
public struct SearchHit: Codable, Sendable {
    public var taskID: TaskID
    public var kind: String
    public var snippet: String
}

extension CollaborationService {

    // MARK: - Storage guard (T30)

    /// Free bytes on the volume holding the Workshop home (injectable).
    public func freeDiskBytes() -> Int64 {
        if let probe = freeSpaceBytes { return probe() }
        guard let homeDir else { return .max }
        let url = URL(fileURLWithPath: homeDir)
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Refuse writes below 200 MiB; one systemEvent per task (T30).
    public func checkStorage(taskID: TaskID? = nil) throws {
        let free = freeDiskBytes()
        guard free < 200 * 1_048_576 else { return }
        if let taskID, !lowDiskNotified.contains(taskID) {
            lowDiskNotified.insert(taskID)
            let t = now()
            _ = try? repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: taskID,
                seq: try repo.nextMessageSeq(taskID), author: .system,
                kind: .systemEvent,
                body: "Storage critically low; new writes refused until space is freed",
                deliveryState: .committed, createdAt: t, updatedAt: t))
            publishCommitted()
        }
        throw WorkshopError.storageLow(freeBytes: free)
    }

    // MARK: - Capacity (§10, T13/T14)

    /// Compute (and persist) a fresh snapshot for an engineer's bucket.
    @discardableResult
    public func measureCapacity(_ engineer: EngineerID) -> QuotaSnapshot? {
        guard let policy = capacityPolicies[engineer] else {
            return try? repo.latestQuotaSnapshot(engineer.rawValue)
        }
        let t = now()
        let dayStart = Calendar.current.startOfDay(for: t)
        let usage = (try? repo.usageToday(engineer, on: dayStart))
            ?? (tokens: 0, hasUnknown: true)
        let held = (try? repo.heldReservationTotal(engineer.rawValue)) ?? 0
        let remaining: String
        let availability: String
        if let cap = policy.dailyTokenCap {
            if usage.hasUnknown {
                remaining = "unknown"
                availability = "unknown"
            } else {
                let left = cap - usage.tokens - held
                remaining = String(left)
                let pct = cap > 0 ? (100 * left) / cap : 0
                // Hysteresis: a bucket that was critical must recover past
                // critical+hysteresis before reporting low again.
                let prior = try? repo.latestQuotaSnapshot(engineer.rawValue)
                let wasCritical = prior?.availability == "critical"
                if pct <= policy.criticalPct {
                    availability = "critical"
                } else if pct <= policy.lowPct
                            || (wasCritical
                                && pct <= policy.criticalPct + policy.hysteresisPct) {
                    availability = "low"
                } else {
                    availability = "available"
                }
            }
        } else {
            remaining = "unknown"
            availability = "unknown"
        }
        let snapshot = QuotaSnapshot(bucket: engineer.rawValue, remaining: remaining,
                                     unit: policy.dailyTokenCap != nil ? "tokens" : nil,
                                     source: "usage_samples", observedAt: t,
                                     availability: availability)
        try? repo.insertQuotaSnapshot(snapshot)
        return snapshot
    }

    /// Record a provider-reported quota hit (402/429) → limited for 15 min.
    public func recordQuotaLimited(_ engineer: EngineerID, detail: String) {
        let t = now()
        try? repo.insertQuotaSnapshot(QuotaSnapshot(
            bucket: engineer.rawValue, remaining: "unknown",
            resetAt: t.addingTimeInterval(15 * 60),
            source: "provider_error", observedAt: t, availability: "limited"))
        // Owner is asked to checkpoint at the end of its current turn.
        checkpointRequested.insert(engineer)
    }

    /// Returns a blocking reason when the bucket must not be dispatched.
    /// "suppressed" means the event was already emitted for this task+bucket.
    private func capacityBlock(for engineer: EngineerID,
                               taskID: TaskID, at timestamp: Date) -> String? {
        let snapshot = measureCapacity(engineer)
        let availability = snapshot?.availability ?? "unknown"
        guard availability == "critical" || availability == "limited"
                || (availability == "unknown" && requireKnownCapacity) else {
            return nil
        }
        let key = taskID.rawValue + ":" + engineer.rawValue
        if capacityBlockedNotified.contains(key) { return "suppressed" }
        capacityBlockedNotified.insert(key)
        // Propose an eligible replacement (§10); small tasks auto-reassign
        // after the turn ends when a valid checkpoint exists.
        var proposal = ""
        if let task = try? repo.task(taskID) {
            let participants = (try? repo.participants(taskID))?.map(\.engineerID) ?? []
            let others = participants.filter { $0 != engineer }
            let replacement = others.first(where: {
                let s = measureCapacity($0)
                return s == nil || s?.availability == "available"
                    || s?.availability == "unknown"
            })
            if let replacement {
                proposal = "; \(replacement.displayName) is an eligible replacement "
                    + "(workshop.reassignSubtask)"
            }
            if task.phase != .researchProposal,
               let sub = try? repo.latestOwnedSubtask(taskID: taskID, owner: engineer),
               (try? repo.latestValidCheckpoint(taskID: taskID,
                                                engineerID: engineer)) != nil,
               let replacement,
               let ok = try? repo.reassignSubtask(sub.id, newOwner: replacement,
                                                  expectedGeneration: sub.generation,
                                                  at: timestamp), ok {
                proposal = "; auto-reassigned to \(replacement.displayName) "
                    + "(generation \(sub.generation + 1), checkpoint exists)"
                _ = try? repo.insertWakeup(taskID: taskID, engineerID: replacement,
                                           reason: "assigned", triggerSeq: nil,
                                           at: timestamp)
                scheduleWakeupCoalescer()
            }
        }
        let reason = availability == "unknown" ? "unknown (require_known_capacity)"
                                               : availability
        return "Dispatch to \(engineer.displayName) blocked: bucket \(reason)\(proposal)"
    }

    /// Hold a per-turn reservation when the bucket has a numeric remaining.
    private func holdReservation(for engineer: EngineerID, taskID: TaskID,
                                 at timestamp: Date) -> String? {
        guard let policy = capacityPolicies[engineer],
              let snapshot = try? repo.latestQuotaSnapshot(engineer.rawValue),
              let remaining = Int(snapshot.remaining) else { return nil }
        // Never oversubscribe: held reservations must stay ≤ remaining.
        let held = (try? repo.heldReservationTotal(engineer.rawValue)) ?? 0
        guard remaining - held >= policy.reservePerTurn else { return nil }
        let id = newID("res")
        try? repo.insertReservation(Reservation(
            id: id, taskID: taskID, engineerID: engineer,
            bucket: engineer.rawValue, reserved: policy.reservePerTurn,
            expiresAt: timestamp.addingTimeInterval(300), createdAt: timestamp))
        return id
    }

    /// Reconcile a held reservation to actual usage after the turn.
    private func reconcileReservation(_ id: String?, usage: UsageSample,
                                      at timestamp: Date) {
        guard let id else { return }
        let parts = [usage.input, usage.output, usage.cacheRead, usage.cacheWrite]
        if parts.contains(where: { $0 == nil }) {
            // Nil counters → actual usage unknown → release, never guess.
            try? repo.updateReservation(id, state: "released", committed: nil,
                                        at: timestamp)
        } else {
            let committed = parts.compactMap { $0 }.reduce(0, +)
            try? repo.updateReservation(id, state: "reconciled",
                                        committed: committed, at: timestamp)
        }
    }

    /// workshop_get_capacity: real snapshots per bucket (T14).
    public func capacitySnapshot() -> JSONValue {
        .object(EngineerID.allCases.reduce(into: [String: JSONValue]()) { acc, e in
            let snapshot = measureCapacity(e)
            acc[e.rawValue] = .object([
                "remaining": .string(snapshot?.remaining ?? "unknown"),
                "availability": .string(snapshot?.availability ?? "unknown"),
                "source": .string(snapshot?.source ?? "not measured"),
                "unit": snapshot?.unit.map(JSONValue.string) ?? .null,
                "reset_at": snapshot?.resetAt
                    .map { .string(WorkshopTime.string($0)) } ?? .null,
                "observed_at": snapshot
                    .map { .string(WorkshopTime.string($0.observedAt)) } ?? .null,
            ])
        })
    }

    /// DeepSeek balance probe (one bounded live call, refreshed ≤ every
    /// 10 min; availability + currency only — no account ids).
    public func refreshDeepSeekBalance(force: Bool = false) async {
        guard let probe = balanceProbe else { return }
        let t = now()
        if !force, let last = lastBalanceRefresh, t.timeIntervalSince(last) < 600 {
            return
        }
        lastBalanceRefresh = t
        if let snapshot = await probe(.deepseek) {
            try? repo.insertQuotaSnapshot(snapshot)
        }
    }

    // MARK: - Reconcile (T29)

    public enum ReconcileCause: String, Sendable { case restart, wake }

    /// T29: recovery pass before any dispatch at service start.
    public func reconcileOnStart() { reconcile(after: .restart) }

    /// Recover interrupted operations after restart or system sleep.
    /// `processAlive` is used on wake only — dead harness → interrupted.
    public func reconcile(after cause: ReconcileCause,
                          processAlive: @Sendable (EngineerID) -> Bool = { _ in true }) {
        let t = now()
        do {
            var interrupted: [Turn] = []
            for turn in try repo.turns(state: "running") {
                let dead = cause == .restart || !processAlive(turn.engineerID)
                guard dead else { continue }
                try repo.updateTurnState(turn.id, "interrupted", at: t)
                interrupted.append(turn)
            }
            for r in try repo.reservations(state: "held") {
                try repo.updateReservation(r.id, state: "released",
                                           committed: nil, at: t)
            }
            for w in try repo.runningWakeups() {
                try repo.setWakeupState(w.id, "pending", at: t)
            }
            // T06: each interrupted turn resumes from the owner's latest valid
            // checkpoint or its subtask blocks pending reconciliation.
            for turn in interrupted {
                guard let subID = turn.subtaskID,
                      let sub = try repo.subtask(subID) else { continue }
                if let checkpoint = try loadValidCheckpoint(
                    taskID: turn.taskID, engineerID: turn.engineerID) {
                    _ = try repo.insertWakeup(
                        taskID: turn.taskID, engineerID: turn.engineerID,
                        reason: "resume_from_checkpoint",
                        triggerSeq: nil, at: t)
                    _ = try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: turn.taskID,
                        seq: try repo.nextMessageSeq(turn.taskID), author: .system,
                        kind: .systemEvent,
                        body: "Resuming \(turn.engineerID.displayName) from "
                            + "checkpoint \(checkpoint.id)",
                        deliveryState: .committed, createdAt: t, updatedAt: t))
                    pendingCheckpointDetail[turn.engineerID] = checkpoint.content
                    scheduleWakeupCoalescer()
                } else {
                    try repo.updateSubtaskState(sub.id, .blocked, at: t)
                    _ = try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: turn.taskID,
                        seq: try repo.nextMessageSeq(turn.taskID), author: .system,
                        kind: .systemEvent,
                        body: "Interrupted turn for \(turn.engineerID.displayName) "
                            + "has no valid checkpoint; subtask blocked pending "
                            + "reconciliation",
                        deliveryState: .committed, createdAt: t, updatedAt: t))
                }
            }
        } catch {
            log.error("reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lease sweeper (T05, §9.2)

    private func scheduleLeaseSweeper() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                let shutdown = await self.isShutdown
                if shutdown { return }
                let asleep = await self.sleeping
                if asleep { continue }
                await self.sweepExpiredLeases()
            }
        }
    }

    /// One lease-heartbeat renewal (CAS on owner+generation).
    private func renewLeaseHeartbeat(subtask: Subtask, engineer: EngineerID) {
        let t = now()
        _ = attempt("leaseHeartbeat") {
            try repo.renewSubtaskLease(subtask.id, owner: engineer,
                                       generation: subtask.generation,
                                       leaseExpiresAt: t.addingTimeInterval(300),
                                       at: t)
        }
    }

    /// Expired subtask leases with no running turn in this process →
    /// blocked + reconciliation event + wakeups suppressed. Test-invokable.
    public func sweepExpiredLeases() {
        let t = now()
        guard let expired = try? repo.subtasksWithExpiredLease(at: t) else { return }
        for sub in expired {
            guard let owner = sub.ownerID else { continue }
            let key = sub.taskID.rawValue + ":" + owner.rawValue
            if runningTurns.contains(key) { continue } // heartbeat may lag
            do {
                try repo.db.transaction {
                    try repo.updateSubtaskState(sub.id, .blocked, at: t)
                    try repo.insertMessage(Message(
                        id: MessageID(newID("msg")), taskID: sub.taskID,
                        seq: try repo.nextMessageSeq(sub.taskID), author: .system,
                        kind: .systemEvent,
                        body: "Lease for \(owner.displayName) expired (generation "
                            + "\(sub.generation)); reconciliation required before "
                            + "reassignment",
                        deliveryState: .committed, createdAt: t, updatedAt: t))
                }
                try repo.suppressPendingWakeups(sub.taskID, at: t)
            } catch {
                log.error("lease sweep failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        publishCommitted()
    }

    // MARK: - Reassignment (T05)

    /// workshop.reassignSubtask — user, or Devin as arbiter. Cancels a
    /// running turn first (adapter enforces the ≤10 s bound + process-group
    /// kill), then CAS-bumps the ownership generation.
    public func reassignSubtask(subtaskID: SubtaskID, newOwner: EngineerID,
                                principal: Principal) async throws {
        if principal != .user, principal.engineerID != .devin {
            throw WorkshopError.userAuthorityRequired("reassign subtask")
        }
        guard let sub = try repo.subtask(subtaskID) else {
            throw WorkshopError.invalidRequest("subtask not found")
        }
        let taskID = sub.taskID
        if let owner = sub.ownerID {
            let key = taskID.rawValue + ":" + owner.rawValue
            if let info = runningTurnRefs[key] {
                _ = await info.adapter.cancelTurn(ref: info.ref, turnID: info.turnID)
            }
        }
        guard try repo.reassignSubtask(subtaskID, newOwner: newOwner,
                                       expectedGeneration: sub.generation,
                                       at: now()) else {
            throw WorkshopError.invalidRequest("reassignment lost the CAS race")
        }
        let t = now()
        try repo.insertMessage(Message(
            id: MessageID(newID("msg")), taskID: taskID,
            seq: try repo.nextMessageSeq(taskID), author: .system,
            kind: .systemEvent,
            body: "\(sub.title) reassigned to \(newOwner.displayName) "
                + "(generation \(sub.generation + 1))",
            deliveryState: .committed, createdAt: t, updatedAt: t))
        _ = try repo.insertWakeup(taskID: taskID, engineerID: newOwner,
                                  reason: "assigned", triggerSeq: nil, at: t)
        publishCommitted()
        scheduleWakeupCoalescer()
    }

    // MARK: - Resource lease tools (T24, §9.2)

    /// workshop_acquire_lease — CAS insert-or-takeover on a named resource.
    public func toolAcquireLease(args: JSONValue, principal: Principal) throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("leases require an engineer principal")
        }
        guard let resource = args["resource"]?.stringValue else {
            throw WorkshopError.invalidRequest("resource required")
        }
        let ttl = min(Int(args["ttl_seconds"]?.intValue ?? 300), 900)
        let taskID = args["task_id"]?.stringValue.map { TaskID($0) }
        guard let lease = try repo.acquireLease(
            resource: resource, owner: engineer.rawValue, taskID: taskID,
            ttlSeconds: ttl, url: args["url"]?.stringValue, at: now()) else {
            throw WorkshopError.invalidRequest("lease held by another owner")
        }
        return .object(["resource": .string(lease.resource),
                        "generation": .number(Double(lease.generation)),
                        "expires_at": .string(WorkshopTime.string(lease.expiresAt))])
    }

    /// workshop_renew_lease — CAS on (resource, owner, generation).
    public func toolRenewLease(args: JSONValue, principal: Principal) throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("leases require an engineer principal")
        }
        guard let resource = args["resource"]?.stringValue,
              let generation = args["generation"]?.intValue else {
            throw WorkshopError.invalidRequest("resource and generation required")
        }
        let ttl = min(Int(args["ttl_seconds"]?.intValue ?? 300), 900)
        guard try repo.renewLease(resource: resource, owner: engineer.rawValue,
                                  generation: Int(generation),
                                  ttlSeconds: ttl, at: now()) else {
            throw WorkshopError.invalidRequest("lease not held at that generation")
        }
        return .object(["resource": .string(resource), "renewed": .bool(true)])
    }

    /// workshop_release_lease — CAS on (resource, owner, generation).
    public func toolReleaseLease(args: JSONValue, principal: Principal) throws -> JSONValue {
        guard let engineer = principal.engineerID else {
            throw WorkshopError.invalidRequest("leases require an engineer principal")
        }
        guard let resource = args["resource"]?.stringValue,
              let generation = args["generation"]?.intValue else {
            throw WorkshopError.invalidRequest("resource and generation required")
        }
        guard try repo.releaseLease(resource: resource, owner: engineer.rawValue,
                                    generation: Int(generation), at: now()) else {
            throw WorkshopError.invalidRequest("lease not held at that generation")
        }
        return .object(["resource": .string(resource), "released": .bool(true)])
    }

    // MARK: - Sleep/wake hooks (T29)

    /// Daemon installs these once; willSleep suppresses sweeps, didWake
    /// reconciles running turns against registered process-liveness probes.
    public func installSleepWakeHooks() {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil,
            queue: nil) { [weak self] _ in
            Task { await self?.setSleeping(true) }
        })
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil,
            queue: nil) { [weak self] _ in
            Task { await self?.wokeFromSleep() }
        })
        #endif
    }

    private func setSleeping(_ value: Bool) { sleeping = value }

    private func wokeFromSleep() {
        sleeping = false
        let probes = harnessAliveProbes
        reconcile(after: .wake) { engineer in probes[engineer]?() ?? true }
    }

    /// Register a liveness probe for an engineer's harness process (daemon).
    public func registerHarnessAlive(_ engineer: EngineerID,
                                     probe: @escaping @Sendable () -> Bool) {
        harnessAliveProbes[engineer] = probe
    }

    /// Test hook: simulate sleep/wake without AppKit notifications.
    public func simulateWake(processAlive: @Sendable (EngineerID) -> Bool
                             = { _ in true }) {
        reconcile(after: .wake, processAlive: processAlive)
    }

    // MARK: - WAL monitor (§14.5)

    private func scheduleWalMonitor() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                let shutdown = await self.isShutdown
                if shutdown { return }
                await self.walCheckpointIfNeeded()
            }
        }
    }

    /// PASSIVE checkpoint when the WAL exceeds 64 MiB (§14.5).
    public func walCheckpointIfNeeded() {
        let path = repo.db.path
        guard path != ":memory:" else { return }
        let wal = path + "-wal"
        let size = (try? FileManager.default.attributesOfItem(atPath: wal))?[.size]
            as? Int64 ?? 0
        guard size > 64 * 1_048_576 else { return }
        _ = try? repo.db.query("PRAGMA wal_checkpoint(PASSIVE)", [])
        lastWalCheckpoint = now()
    }

    // MARK: - Diagnostics (§14.5)

    public func diagnostics() async -> JSONValue {
        var probes: [String: JSONValue] = [:]
        for engineer in EngineerID.allCases {
            if let adapter = adapters[engineer] {
                let probe = await adapter.probe()
                probes[engineer.rawValue] = .object([
                    "health": .string(probe.health.kind.rawValue),
                    "detail": .string(Redactor.shared.redact(probe.health.detail)),
                ])
            }
        }
        let running = (try? repo.turns(state: "running")) ?? []
        let pending = (try? repo.pendingWakeups()) ?? []
        var snapshots: [String: JSONValue] = [:]
        for engineer in EngineerID.allCases {
            if let s = try? repo.latestQuotaSnapshot(engineer.rawValue) {
                snapshots[engineer.rawValue] = .object([
                    "availability": .string(s.availability),
                    "remaining": .string(s.remaining),
                    "observed_at": .string(WorkshopTime.string(s.observedAt)),
                    "source": .string(s.source),
                ])
            }
        }
        let dbPath = repo.db.path
        let fileSize = { (p: String) -> Int64 in
            (try? FileManager.default.attributesOfItem(atPath: p))?[.size]
                as? Int64 ?? 0
        }
        var artifactsSize: Int64 = 0
        if let homeDir {
            let dir = homeDir + "/artifacts"
            for taskDir in (try? fmContents(dir)) ?? [] {
                for f in (try? fmContents(dir + "/" + taskDir)) ?? [] {
                    artifactsSize += fileSize(dir + "/" + taskDir + "/" + f)
                }
            }
        }
        return .object([
            "harnesses": .object(probes),
            "running_turns": .array(running.map { .string($0.id) }),
            "pending_wakeups": .number(Double(pending.count)),
            "db_size_bytes": .number(Double(fileSize(dbPath))),
            "wal_size_bytes": .number(Double(fileSize(dbPath + "-wal"))),
            "artifacts_size_bytes": .number(Double(artifactsSize)),
            "last_wal_checkpoint": lastWalCheckpoint
                .map { .string(WorkshopTime.string($0)) } ?? .null,
            "capacity": .object(snapshots),
            "sleeping": .bool(sleeping),
            "free_disk_bytes": .number(Double(freeDiskBytes())),
            "sqlite_fts5": .bool(sqliteHasFTS5),
        ])
    }

    private func fmContents(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    // MARK: - Search (§14.1)

    /// FTS5 when the SQLite build has it, LIKE otherwise. One hit per
    /// matching message/decision/artifact with task + snippet.
    public func search(query: String, limit: Int = 50) throws -> [SearchHit] {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%" + escaped + "%"
        var hits: [SearchHit] = []
        let mrows = try repo.db.query("""
            SELECT task_id, body FROM messages
            WHERE body LIKE ? ESCAPE '\\' ORDER BY seq DESC LIMIT ?
            """, [.text(pattern), .integer(Int64(limit))])
        for r in mrows {
            hits.append(SearchHit(taskID: TaskID(r["task_id"]!.text!),
                                  kind: "message",
                                  snippet: snippet(r["body"]!.text!, query)))
        }
        let drows = try repo.db.query("""
            SELECT task_id, kind, body FROM decisions
            WHERE body LIKE ? ESCAPE '\\' LIMIT ?
            """, [.text(pattern), .integer(Int64(limit))])
        for r in drows {
            hits.append(SearchHit(taskID: TaskID(r["task_id"]!.text!),
                                  kind: "decision:" + (r["kind"]?.text ?? ""),
                                  snippet: snippet(r["body"]!.text!, query)))
        }
        let arows = try repo.db.query("""
            SELECT task_id, relative_path FROM artifacts
            WHERE relative_path LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\'
            LIMIT ?
            """, [.text(pattern), .text(pattern), .integer(Int64(limit))])
        for r in arows {
            hits.append(SearchHit(taskID: TaskID(r["task_id"]!.text!),
                                  kind: "artifact",
                                  snippet: r["relative_path"]!.text!))
        }
        return Array(hits.prefix(limit))
    }

    /// Whether the linked SQLite has FTS5 (reported in diagnostics/validation).
    public var sqliteHasFTS5: Bool {
        (try? repo.db.query("PRAGMA compile_options", []))?
            .contains { $0.values.contains { $0.text == "ENABLE_FTS5" } } ?? false
    }

    private func snippet(_ body: String, _ query: String) -> String {
        guard let range = body.range(of: query, options: .caseInsensitive) else {
            return String(body.prefix(120))
        }
        let start = body.index(range.lowerBound, offsetBy: -40,
                               limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: 80,
                             limitedBy: body.endIndex) ?? body.endIndex
        return String(body[start..<end])
    }

    // MARK: - Export (§14.1)

    /// workshop.exportTask — <title>.md + manifest.json + copied artifacts,
    /// redacted; private continuation never included.
    public func exportTask(taskID: TaskID, destDir: String) throws -> JSONValue {
        let task = try loadTask(taskID)
        let fm = FileManager.default
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let messages = try repo.messages(taskID, afterSeq: 0, limit: 10_000)
            .filter { $0.deliveryState == .committed }
        let decisions = try repo.decisions(taskID)
        let proposals = try repo.proposals(taskID).filter { $0.visibility == "published" }
        let artifacts = try repo.artifacts(taskID)
        let report = try repo.latestReport(taskID)
        let redactor = Redactor.shared

        var md = "# \(task.title)\n\nState: \(task.state.rawValue)\n\n## Messages\n\n"
        for m in messages {
            md += "### [\(m.seq)] \(m.author.displayName) — "
                + WorkshopTime.string(m.createdAt) + "\n\n"
            md += redactor.redact(m.body) + "\n\n"
        }
        if !decisions.isEmpty {
            md += "## Decisions\n\n"
            for d in decisions {
                md += "- \(d.kind) r\(d.revision.map(String.init) ?? "-") "
                    + "by \(d.author) — \(redactor.redact(d.body))\n"
            }
            md += "\n"
        }
        if !proposals.isEmpty {
            md += "## Proposals\n\n"
            for p in proposals {
                md += "### \(p.author.displayName)\n\n"
                    + redactor.redact(p.content) + "\n\n"
            }
        }
        if let report {
            md += "## Report (r\(report.revision))\n\n"
                + redactor.redact(report.content) + "\n"
        }
        md += "## Artifacts\n\n| sha256 | path | producer |\n|---|---|---|\n"
        var manifestArtifacts: [JSONValue] = []
        let artDir = destDir + "/artifacts"
        try fm.createDirectory(atPath: artDir, withIntermediateDirectories: true)
        for a in artifacts {
            let src = (homeDir ?? "") + "/" + a.relativePath
            let dest = artDir + "/" + (a.relativePath as NSString).lastPathComponent
            try? fm.copyItem(atPath: src, toPath: dest)
            md += "| \(a.contentHash) | \(a.relativePath) | \(a.producer) |\n"
            manifestArtifacts.append(.object([
                "sha256": .string(a.contentHash),
                "path": .string("artifacts/"
                    + (a.relativePath as NSString).lastPathComponent),
                "producer": .string(a.producer),
            ]))
        }
        let title = task.title.replacingOccurrences(of: "/", with: "-")
        try md.write(toFile: destDir + "/" + title + ".md",
                     atomically: true, encoding: .utf8)
        // Model/version provenance per engineer from usage samples.
        var provenance: [String: JSONValue] = [:]
        for sample in try repo.usageSamples(taskID) {
            provenance[sample.engineerID.rawValue] = .object([
                "provider": .string(sample.provider),
                "model": sample.model.map(JSONValue.string) ?? .null,
                "native_session_id": sample.nativeSessionID
                    .map(JSONValue.string) ?? .null,
            ])
        }
        let manifest: JSONValue = .object([
            "task_id": .string(taskID.rawValue),
            "title": .string(task.title),
            "exported_at": .string(WorkshopTime.string(now())),
            "artifacts": .array(manifestArtifacts),
            "provenance": .object(provenance),
        ])
        try JSONEncoder().encode(manifest)
            .write(to: URL(fileURLWithPath: destDir + "/manifest.json"))
        return .object(["dest_dir": .string(destDir),
                        "task_id": .string(taskID.rawValue)])
    }

    // MARK: - Backup (§14.3, T38)

    /// sqlite3 online backup of the DB + artifacts copy + manifest with
    /// hashes. Works while a writer is active (the backup API handles locks).
    public func backup(destDir: String) throws -> JSONValue {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let srcPath = repo.db.path
        guard srcPath != ":memory:" else {
            throw WorkshopError.invalidRequest("in-memory database cannot be backed up")
        }
        let destDB = destDir + "/workshop.sqlite"
        try? fm.removeItem(atPath: destDB)
        var src: OpaquePointer?
        var dst: OpaquePointer?
        guard sqlite3_open(srcPath, &src) == SQLITE_OK,
              sqlite3_open(destDB, &dst) == SQLITE_OK else {
            sqlite3_close(src); sqlite3_close(dst)
            throw WorkshopError.invalidRequest("backup open failed")
        }
        defer { sqlite3_close(src); sqlite3_close(dst) }
        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw WorkshopError.invalidRequest("sqlite3_backup_init failed")
        }
        var rc = sqlite3_backup_step(backup, -1)
        while rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
            usleep(50_000)
            rc = sqlite3_backup_step(backup, -1)
        }
        let finish = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE, finish == SQLITE_OK else {
            throw WorkshopError.invalidRequest("backup step failed (rc=\(rc))")
        }
        // Copy artifacts + manifest with hashes.
        var hashes: [String: String] = [:]
        if let homeDir {
            let srcArt = homeDir + "/artifacts"
            let dstArt = destDir + "/artifacts"
            for taskDir in (try? fmContents(srcArt)) ?? [] {
                for f in (try? fmContents(srcArt + "/" + taskDir)) ?? [] {
                    let src = srcArt + "/" + taskDir + "/" + f
                    let dst = dstArt + "/" + taskDir + "/" + f
                    try fm.createDirectory(atPath: dstArt + "/" + taskDir,
                                           withIntermediateDirectories: true)
                    try? fm.removeItem(atPath: dst)
                    try fm.copyItem(atPath: src, toPath: dst)
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: src)) {
                        let h = SHA256.hash(data: data)
                            .map { String(format: "%02x", $0) }.joined()
                        hashes["artifacts/\(taskDir)/\(f)"] = h
                    }
                }
            }
        }
        let manifest: JSONValue = .object([
            "backed_up_at": .string(WorkshopTime.string(now())),
            "schema_version": .number(4),
            "artifact_hashes": .object(hashes.mapValues { .string($0) }),
        ])
        try JSONEncoder().encode(manifest)
            .write(to: URL(fileURLWithPath: destDir + "/manifest.json"))
        return .object(["dest_dir": .string(destDir)])
    }

    // MARK: - Recovery summary (UI banner)

    /// "Recovered: N interrupted turns, M unresolved operations" (§14.1 UI).
    public func recoverySummary(taskID: TaskID) throws -> String? {
        let interrupted = try repo.turns(taskID: taskID, state: "interrupted").count
        let released = try repo.reservations(taskID: taskID, state: "released").count
        guard interrupted > 0 || released > 0 else { return nil }
        return "Recovered: \(interrupted) interrupted turns, "
            + "\(released) unresolved operations"
    }
}
