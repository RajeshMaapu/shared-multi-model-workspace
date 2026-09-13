import Foundation
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

    public init(database: Database, adapters: [EngineerAdapter],
                dispatcherEnabled: Bool = true,
                now: @escaping () -> Date = Date.init) throws {
        try Migrations.all.migrate(database)
        self.repo = WorkshopRepository(db: database)
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.engineer, $0) })
        self.dispatcherEnabled = dispatcherEnabled
        self.now = now
    }

    public convenience init(databasePath: String, adapters: [EngineerAdapter],
                            dispatcherEnabled: Bool = true,
                            now: @escaping () -> Date = Date.init) throws {
        try self.init(database: try Database(path: databasePath), adapters: adapters,
                      dispatcherEnabled: dispatcherEnabled, now: now)
    }

    /// Recovery, then process any pending dispatch rows exactly once (T03).
    public func start() async {
        recoverInterruptedStreams()
        scheduleDispatch()
    }

    public func shutdown() {
        isShutdown = true
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    /// Wait until the dispatcher has no pending work. For tests.
    public func awaitIdle() async {
        while dispatcherScheduled || inflightTurns > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if let pending = try? repo.pendingOutbox(eventType: Self.dispatchRequested),
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
        guard let rows = try? repo.outboxEvents(afterSeq: lastPublishedSeq) else { return }
        for row in rows {
            lastPublishedSeq = max(lastPublishedSeq, row.seq)
            for continuation in eventContinuations.values {
                continuation.yield(row)
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
        return TaskDetail(task: task,
                          participants: try repo.participants(id),
                          subtasks: try repo.subtasks(id))
    }

    public func readMessages(_ taskID: TaskID, afterSeq: Int64 = 0, limit: Int = 500) throws -> [Message] {
        try repo.messages(taskID, afterSeq: afterSeq, limit: limit)
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
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: taskID,
                    seq: try repo.nextMessageSeq(taskID), author: .system,
                    kind: .systemEvent,
                    body: "Research/proposal phase requires the Phase 3 collaboration "
                        + "policy, which is not yet implemented. Task preserved in Queued.",
                    deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
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
        return receipt!
    }

    /// Append a user reply to an existing task; does not create a task.
    public func postMessage(taskID: TaskID, body: String) throws -> Message {
        guard try repo.task(taskID) != nil else { throw WorkshopError.taskNotFound(taskID) }
        let timestamp = now()
        let message = Message(id: MessageID(newID("msg")), taskID: taskID,
                              seq: 0, author: .user, kind: .text, body: body,
                              deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp)
        try repo.db.transaction {
            let m = Message(id: message.id, taskID: taskID, seq: try repo.nextMessageSeq(taskID),
                            author: .user, kind: .text, body: body,
                            deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp)
            try repo.insertMessage(m)
            try repo.insertOutbox(taskID: taskID, eventType: "message.committed",
                                  payload: #"{"message_id":""# + m.id.rawValue
                                      + #"","task_id":""# + taskID.rawValue + #""}"#,
                                  deliveryState: "pending", at: timestamp)
        }
        publishCommitted()
        return try repo.message(message.id)!
    }

    // MARK: - Recovery

    /// Mark messages left `streaming` by a previous process as committed + uncertain.
    private func recoverInterruptedStreams() {
        guard let interrupted = try? repo.streamingMessages(), !interrupted.isEmpty else { return }
        let timestamp = now()
        for message in interrupted {
            try? repo.db.transaction {
                try repo.updateMessageBody(
                    message.id,
                    body: message.body
                        + "\n\n[stream interrupted by service restart; marked uncertain]",
                    at: timestamp)
                try repo.updateMessageDelivery(message.id, .committed, at: timestamp)
                try repo.insertMessage(Message(
                    id: MessageID(newID("msg")), taskID: message.taskID,
                    seq: try repo.nextMessageSeq(message.taskID), author: .system,
                    kind: .systemEvent,
                    body: "Interrupted stream marked uncertain after service restart.",
                    deliveryState: .committed, createdAt: timestamp, updatedAt: timestamp))
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
            guard let rows = try? repo.pendingOutbox(eventType: Self.dispatchRequested),
                  let row = rows.first else { break }
            await handleDispatch(row)
        }
        dispatcherScheduled = false
    }

    /// Exposed for tests that drive the dispatcher manually.
    public func processPendingDispatches() async {
        await dispatchLoop()
    }

    /// Test hook: run the CAS claim directly (concurrent callers → exactly one winner).
    public func claimForTest(subtaskID: SubtaskID, owner: EngineerID,
                             expectedGeneration: Int) throws -> Bool {
        try repo.claimSubtask(subtaskID, owner: owner, expectedGeneration: expectedGeneration,
                              leaseExpiresAt: now().addingTimeInterval(300), at: now())
    }

    /// Test hook: leave an uncommitted streaming message behind, as a crashed turn would.
    public func insertStreamingMessageForTest() throws {
        guard let task = try repo.listTasks().first else { return }
        let timestamp = now()
        try repo.insertMessage(Message(
            id: MessageID(newID("msg")), taskID: task.id,
            seq: try repo.nextMessageSeq(task.id), author: .engineer(.devin),
            kind: .text, body: "partial reply", deliveryState: .streaming,
            createdAt: timestamp, updatedAt: timestamp))
    }

    private func handleDispatch(_ row: OutboxEvent) async {
        guard let payload = try? JSONDecoder().decode(JSONValue.self,
                                                      from: Data(row.payload.utf8)),
              let taskIDRaw = payload["task_id"]?.stringValue,
              let subtaskIDRaw = payload["subtask_id"]?.stringValue else {
            try? repo.db.transaction { try repo.markOutboxDelivered(row.seq, at: now()) }
            publishCommitted()
            return
        }
        let taskID = TaskID(taskIDRaw)
        let subtaskID = SubtaskID(subtaskIDRaw)
        let preferredOwner = payload["preferred_owner"]?.stringValue
            .flatMap(EngineerID.init(rawValue:))

        guard let task = try? repo.task(taskID),
              var subtask = try? repo.subtask(subtaskID) else {
            try? repo.db.transaction { try repo.markOutboxDelivered(row.seq, at: now()) }
            publishCommitted()
            return
        }

        // Eligible engineers: participants whose probe reports available (spec §5.2).
        var order = EngineerID.allCases
        if let preferredOwner, let index = order.firstIndex(of: preferredOwner) {
            order.remove(at: index)
            order.insert(preferredOwner, at: 0)
        }
        let participantIDs = (try? repo.participants(taskID))?.map(\.engineerID) ?? []
        var winner: EngineerID?
        for engineer in order where participantIDs.contains(engineer) {
            guard let adapter = adapters[engineer] else { continue }
            let probe = await adapter.probe()
            if probe.health.kind == .available {
                winner = engineer
                break
            }
        }

        guard let winner, let adapter = adapters[winner] else {
            // No eligible engineer: blocked, system event, no retry storm (T15-lite).
            let timestamp = now()
            try? repo.db.transaction {
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
            publishCommitted()
            return
        }

        // Atomic CAS claim; changes()==1 is the single winner (T04).
        let timestamp = now()
        let lease = timestamp.addingTimeInterval(300)
        var claimed = false
        try? repo.db.transaction {
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
        publishCommitted()
        guard claimed else { return }

        subtask = (try? repo.subtask(subtaskID)) ?? subtask

        // Run the turn outside the claim transaction.
        inflightTurns += 1
        defer { inflightTurns -= 1 }
        await runTurn(adapter: adapter, engineer: winner, task: task, subtask: subtask)
    }

    /// Transition helper: verifies the §8.2 edge, no-op when already at `to`.
    private func transition(_ taskID: TaskID, from: TaskState, to: TaskState, at timestamp: Date) throws {
        if from == to { return }
        guard from.canTransition(to: to) else {
            throw WorkshopError.illegalTransition(from: from, to: to)
        }
        try repo.updateTaskState(taskID, to, at: timestamp)
    }

    private func runTurn(adapter: EngineerAdapter, engineer: EngineerID,
                         task: WorkshopTask, subtask: Subtask) async {
        let timestamp = now()
        let binding = SessionBinding(taskID: task.id, engineerID: engineer, role: "owner",
                                     workerID: "main")
        guard let ref = try? await adapter.openTaskSession(binding: binding) else { return }

        // Streaming placeholder message in its own transaction.
        let messageID = MessageID(newID("msg"))
        try? repo.db.transaction {
            try repo.insertMessage(Message(
                id: messageID, taskID: task.id, seq: try repo.nextMessageSeq(task.id),
                author: .engineer(engineer), kind: .text, body: "",
                deliveryState: .streaming, createdAt: timestamp, updatedAt: timestamp))
        }

        var body = ""
        var usage: (input: Int?, output: Int?, cacheRead: Int?, cacheWrite: Int?)? = nil
        let context = TurnContext(task: task, subtask: subtask,
                                  recentMessages: (try? repo.messages(task.id)) ?? [])
        let stream = adapter.sendTurn(ref: ref, turnID: newID("turn"), context: context,
                                      deadline: timestamp.addingTimeInterval(300))
        do {
            for try await event in stream {
                switch event {
                case .messageDelta(let delta):
                    body += delta
                    try? repo.updateMessageBody(messageID, body: body, at: now())
                    publishTransient(taskID: task.id, type: "message.delta",
                                     payload: #"{"message_id":""# + messageID.rawValue
                                         + #"","task_id":""# + task.id.rawValue + #""}"#)
                case .usageSample(let input, let output, let cacheRead, let cacheWrite, _):
                    usage = (input, output, cacheRead, cacheWrite)
                default:
                    break
                }
            }
        } catch {
            // Turn failed mid-stream: mark uncertain truthfully.
            body += "\n\n[turn failed: \(error.localizedDescription); marked uncertain]"
        }

        // Commit the completed turn.
        let endTime = now()
        try? repo.db.transaction {
            try repo.updateMessageBody(messageID, body: body, at: endTime)
            try repo.updateMessageDelivery(messageID, .committed, at: endTime)
            try repo.updateSubtaskState(subtask.id, .review, at: endTime)
            if let current = try repo.task(task.id) {
                try transition(task.id, from: current.state, to: .verifying, at: endTime)
            }
            try repo.insertMessage(Message(
                id: MessageID(newID("msg")), taskID: task.id,
                seq: try repo.nextMessageSeq(task.id), author: .system, kind: .systemEvent,
                body: "Owner reported complete; verification pending",
                deliveryState: .committed, createdAt: endTime, updatedAt: endTime))
            try repo.insertOutbox(taskID: task.id, eventType: "message.committed",
                                  payload: #"{"message_id":""# + messageID.rawValue
                                      + #"","task_id":""# + task.id.rawValue + #""}"#,
                                  deliveryState: "pending", at: endTime)
            var statePayload = #"{"task_id":""# + task.id.rawValue + #"","state":"verifying""#
            if let usage {
                statePayload += #",\"usage\":{\"input\":\#(usage.input ?? 0)"#
                    + #",\"output\":\#(usage.output ?? 0)}"#
            }
            statePayload += "}"
            try repo.insertOutbox(taskID: task.id, eventType: "task.state_changed",
                                  payload: statePayload, deliveryState: "pending",
                                  at: endTime)
        }
        publishCommitted()
    }
}
