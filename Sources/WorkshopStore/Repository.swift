import Foundation
import WorkshopCore

/// Typed persistence functions. Only called from the service actor.
public final class WorkshopRepository {
    public let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - Tasks

    public func insertTask(_ task: WorkshopTask) throws {
        try db.execute("""
            INSERT INTO tasks(id, channel, title, brief, phase, state, scope_revision,
                              approval_revision, budget_policy_ref, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(task.id.rawValue), .text(task.channel), .text(task.title),
                .text(task.brief), .text(task.phase.rawValue), .text(task.state.rawValue),
                .integer(Int64(task.scopeRevision)),
                task.approvalRevision.map { .integer(Int64($0)) },
                task.budgetPolicyRef.map(SQLiteValue.text),
                .text(WorkshopTime.string(task.createdAt)),
                .text(WorkshopTime.string(task.updatedAt)),
            ])
    }

    public func task(_ id: TaskID) throws -> WorkshopTask? {
        try db.query("SELECT * FROM tasks WHERE id=?", [.text(id.rawValue)]).first.map(taskFrom)
    }

    public func listTasks() throws -> [WorkshopTask] {
        try db.query("SELECT * FROM tasks ORDER BY created_at DESC, id DESC").map(taskFrom)
    }

    public func updateTaskState(_ id: TaskID, _ state: TaskState, at now: Date) throws {
        try db.execute("UPDATE tasks SET state=?, updated_at=? WHERE id=?", [
            .text(state.rawValue), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
    }

    private func taskFrom(_ r: Row) -> WorkshopTask {
        WorkshopTask(
            id: TaskID(r["id"]!.text!),
            channel: r["channel"]!.text!,
            title: r["title"]!.text!,
            brief: r["brief"]!.text!,
            phase: TaskPhase(rawValue: r["phase"]!.text!) ?? .execution,
            state: TaskState(rawValue: r["state"]!.text!) ?? .draft,
            scopeRevision: Int(r["scope_revision"]!.int ?? 1),
            approvalRevision: r["approval_revision"]?.int.map(Int.init),
            budgetPolicyRef: r["budget_policy_ref"]?.text,
            createdAt: WorkshopTime.date(r["created_at"]!.text!),
            updatedAt: WorkshopTime.date(r["updated_at"]!.text!)
        )
    }

    // MARK: - Participants

    public func insertParticipant(_ p: Participant) throws {
        let subs = String(data: (try? JSONEncoder().encode(p.subscriptions)) ?? Data(), encoding: .utf8) ?? "[]"
        try db.execute("""
            INSERT INTO participants(task_id, engineer_id, membership, read_cursor, subscriptions)
            VALUES(?,?,?,?,?)
            """, [
                .text(p.taskID.rawValue), .text(p.engineerID.rawValue),
                .text(p.membership), .integer(p.readCursor), .text(subs),
            ])
    }

    public func participants(_ taskID: TaskID) throws -> [Participant] {
        try db.query("SELECT * FROM participants WHERE task_id=? ORDER BY engineer_id",
                     [.text(taskID.rawValue)]).map { r in
            let subs = r["subscriptions"]?.text
                .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            return Participant(
                taskID: taskID,
                engineerID: EngineerID(rawValue: r["engineer_id"]!.text!) ?? .devin,
                membership: r["membership"]!.text!,
                readCursor: r["read_cursor"]!.int ?? 0,
                lastReadSeq: r["last_read_seq"]?.int ?? 0,
                subscriptions: subs
            )
        }
    }

    public func participant(_ taskID: TaskID, _ engineerID: EngineerID) throws -> Participant? {
        try participants(taskID).first { $0.engineerID == engineerID }
    }

    /// Advance the consumed-by-turn cursor (§8.5); only ever moves forward.
    public func setLastReadSeq(_ taskID: TaskID, _ engineerID: EngineerID,
                             seq: Int64, at now: Date) throws {
        try db.execute("""
            UPDATE participants SET last_read_seq=MAX(last_read_seq, ?)
            WHERE task_id=? AND engineer_id=?
            """, [.integer(seq), .text(taskID.rawValue), .text(engineerID.rawValue)])
    }

    // MARK: - Messages

    public func nextMessageSeq(_ taskID: TaskID) throws -> Int64 {
        (try db.query("SELECT MAX(seq) AS m FROM messages WHERE task_id=?",
                      [.text(taskID.rawValue)]).first?["m"]?.int ?? 0) + 1
    }

    public func insertMessage(_ m: Message) throws {
        try db.execute("""
            INSERT INTO messages(id, task_id, seq, author_kind, author_id, kind, body,
                                 reply_to, correlation_id, revision, delivery_state,
                                 structured, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(m.id.rawValue), .text(m.taskID.rawValue), .integer(m.seq),
                .text(m.author.kind), m.author.engineerID.map { .text($0.rawValue) },
                .text(m.kind.rawValue), .text(m.body),
                m.replyTo.map { .text($0.rawValue) },
                m.correlationID.map(SQLiteValue.text),
                .integer(Int64(m.revision)), .text(m.deliveryState.rawValue),
                m.structured.map(SQLiteValue.text),
                .text(WorkshopTime.string(m.createdAt)),
                .text(WorkshopTime.string(m.updatedAt)),
            ])
    }

    public func messages(_ taskID: TaskID, afterSeq: Int64 = 0, limit: Int = 500) throws -> [Message] {
        try db.query("""
            SELECT * FROM messages WHERE task_id=? AND seq>? ORDER BY seq LIMIT ?
            """, [.text(taskID.rawValue), .integer(afterSeq), .integer(Int64(limit))]).map(messageFrom)
    }

    public func message(_ id: MessageID) throws -> Message? {
        try db.query("SELECT * FROM messages WHERE id=?", [.text(id.rawValue)]).first.map(messageFrom)
    }

    public func streamingMessages() throws -> [Message] {
        try db.query("SELECT * FROM messages WHERE delivery_state='streaming'").map(messageFrom)
    }

    public func updateMessageBody(_ id: MessageID, body: String, at now: Date) throws {
        try db.execute("UPDATE messages SET body=?, updated_at=? WHERE id=?", [
            .text(body), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
    }

    public func updateMessageDelivery(_ id: MessageID, _ state: DeliveryState, at now: Date) throws {
        try db.execute("UPDATE messages SET delivery_state=?, updated_at=? WHERE id=?", [
            .text(state.rawValue), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
    }

    private func messageFrom(_ r: Row) -> Message {
        Message(
            id: MessageID(r["id"]!.text!),
            taskID: TaskID(r["task_id"]!.text!),
            seq: r["seq"]!.int ?? 0,
            author: Principal(kind: r["author_kind"]!.text!, engineerID: r["author_id"]?.text),
            kind: MessageKind(rawValue: r["kind"]!.text!) ?? .text,
            body: r["body"]!.text!,
            replyTo: r["reply_to"]?.text.map { MessageID($0) },
            correlationID: r["correlation_id"]?.text,
            revision: Int(r["revision"]!.int ?? 1),
            deliveryState: DeliveryState(rawValue: r["delivery_state"]!.text!) ?? .committed,
            structured: r["structured"]?.text,
            createdAt: WorkshopTime.date(r["created_at"]!.text!),
            updatedAt: WorkshopTime.date(r["updated_at"]!.text!)
        )
    }

    // MARK: - Subtasks

    public func insertSubtask(_ s: Subtask) throws {
        try db.execute("""
            INSERT INTO subtasks(id, task_id, title, acceptance, dependencies, owner_id,
                                 generation, lease_expires_at, state, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(s.id.rawValue), .text(s.taskID.rawValue), .text(s.title),
                .text(encodeList(s.acceptance)), .text(encodeList(s.dependencies)),
                s.ownerID.map { .text($0.rawValue) },
                .integer(Int64(s.generation)),
                s.leaseExpiresAt.map { .text(WorkshopTime.string($0)) },
                .text(s.state.rawValue),
                .text(WorkshopTime.string(s.createdAt)),
                .text(WorkshopTime.string(s.updatedAt)),
            ])
    }

    public func subtask(_ id: SubtaskID) throws -> Subtask? {
        try db.query("SELECT * FROM subtasks WHERE id=?", [.text(id.rawValue)]).first.map(subtaskFrom)
    }

    public func subtasks(_ taskID: TaskID) throws -> [Subtask] {
        try db.query("SELECT * FROM subtasks WHERE task_id=? ORDER BY created_at, id",
                     [.text(taskID.rawValue)]).map(subtaskFrom)
    }

    /// Atomic compare-and-swap claim. Exactly one concurrent caller wins (spec §5.2).
    public func claimSubtask(_ id: SubtaskID, owner: EngineerID, expectedGeneration: Int,
                             leaseExpiresAt: Date, at now: Date) throws -> Bool {
        try db.execute("""
            UPDATE subtasks
            SET owner_id=?, generation=generation+1, state='claimed',
                lease_expires_at=?, updated_at=?
            WHERE id=? AND owner_id IS NULL AND generation=?
            """, [
                .text(owner.rawValue), .text(WorkshopTime.string(leaseExpiresAt)),
                .text(WorkshopTime.string(now)), .text(id.rawValue),
                .integer(Int64(expectedGeneration)),
            ])
        return db.changes() == 1
    }

    public func updateSubtaskState(_ id: SubtaskID, _ state: SubtaskState, at now: Date) throws {
        try db.execute("UPDATE subtasks SET state=?, updated_at=? WHERE id=?", [
            .text(state.rawValue), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
    }

    private func subtaskFrom(_ r: Row) -> Subtask {
        Subtask(
            id: SubtaskID(r["id"]!.text!),
            taskID: TaskID(r["task_id"]!.text!),
            title: r["title"]!.text!,
            acceptance: decodeList(r["acceptance"]?.text),
            dependencies: decodeList(r["dependencies"]?.text),
            ownerID: r["owner_id"]?.text.flatMap(EngineerID.init(rawValue:)),
            generation: Int(r["generation"]!.int ?? 0),
            leaseExpiresAt: r["lease_expires_at"]?.text.map(WorkshopTime.date),
            state: SubtaskState(rawValue: r["state"]!.text!) ?? .ready,
            createdAt: WorkshopTime.date(r["created_at"]!.text!),
            updatedAt: WorkshopTime.date(r["updated_at"]!.text!)
        )
    }

    // MARK: - Operations (idempotency)

    public struct StoredOperation {
        public let idempotencyKey: String
        public let principal: String
        public let payloadHash: String
        public let resultJSON: String
    }

    public func operation(_ key: String) throws -> StoredOperation? {
        try db.query("SELECT * FROM operations WHERE idempotency_key=?", [.text(key)])
            .first.map {
                StoredOperation(
                    idempotencyKey: $0["idempotency_key"]!.text!,
                    principal: $0["principal"]!.text!,
                    payloadHash: $0["payload_hash"]!.text!,
                    resultJSON: $0["result_json"]!.text!
                )
            }
    }

    public func insertOperation(key: String, principal: String, payloadHash: String,
                                resultJSON: String, at now: Date) throws {
        try db.execute("""
            INSERT INTO operations(idempotency_key, principal, payload_hash, result_json, created_at)
            VALUES(?,?,?,?,?)
            """, [.text(key), .text(principal), .text(payloadHash), .text(resultJSON),
                  .text(WorkshopTime.string(now))])
    }

    // MARK: - Outbox

    @discardableResult
    public func insertOutbox(taskID: TaskID?, eventType: String, recipients: [String] = [],
                             payload: String, deliveryState: String, at now: Date) throws -> Int64 {
        try db.execute("""
            INSERT INTO outbox(task_id, event_type, recipients, payload, delivery_state, created_at)
            VALUES(?,?,?,?,?,?)
            """, [
                taskID.map { .text($0.rawValue) } ?? nil,
                .text(eventType), .text(encodeList(recipients)),
                .text(payload), .text(deliveryState), .text(WorkshopTime.string(now)),
            ])
        return db.lastInsertRowID()
    }

    public func pendingOutbox(eventType: String, deliveryState: String = "pending") throws -> [OutboxEvent] {
        try db.query("""
            SELECT * FROM outbox WHERE event_type=? AND delivery_state=? ORDER BY seq
            """, [.text(eventType), .text(deliveryState)]).map(outboxFrom)
    }

    public func outboxEvents(afterSeq: Int64, limit: Int = 500) throws -> [OutboxEvent] {
        try db.query("SELECT * FROM outbox WHERE seq>? ORDER BY seq LIMIT ?",
                     [.integer(afterSeq), .integer(Int64(limit))]).map(outboxFrom)
    }

    public func markOutboxDelivered(_ seq: Int64, at now: Date) throws {
        try db.execute("UPDATE outbox SET delivery_state='delivered', delivered_at=? WHERE seq=?", [
            .text(WorkshopTime.string(now)), .integer(seq),
        ])
    }

    /// Mark a row permanently failed; reason appended to the payload text.
    public func markOutboxFailed(_ seq: Int64, reason: String, at now: Date) throws {
        try db.execute("""
            UPDATE outbox SET delivery_state='failed',
                payload = payload || ' [error: ' || ? || ']', delivered_at=?
            WHERE seq=?
            """, [.text(reason), .text(WorkshopTime.string(now)), .integer(seq)])
    }

    public func latestOutboxEvent(taskID: TaskID, eventType: String) throws -> OutboxEvent? {
        try db.query("""
            SELECT * FROM outbox WHERE task_id=? AND event_type=? ORDER BY seq DESC LIMIT 1
            """, [.text(taskID.rawValue), .text(eventType)]).first.map(outboxFrom)
    }

    /// The latest-generation subtask owned by an engineer on a task.
    public func latestOwnedSubtask(taskID: TaskID, owner: EngineerID) throws -> Subtask? {
        try db.query("""
            SELECT * FROM subtasks WHERE task_id=? AND owner_id=?
            ORDER BY generation DESC, created_at DESC LIMIT 1
            """, [.text(taskID.rawValue), .text(owner.rawValue)]).first.map(subtaskFrom)
    }

    // MARK: - Artifacts

    public func insertArtifact(_ a: Artifact) throws {
        try db.execute("""
            INSERT INTO artifacts(id, task_id, content_hash, relative_path, mime, producer,
                                  base_revision, validation, description, created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(a.id), .text(a.taskID.rawValue), .text(a.contentHash),
                .text(a.relativePath), a.mime.map(SQLiteValue.text), .text(a.producer),
                a.baseRevision.map(SQLiteValue.text), .text(a.validation),
                a.description.map(SQLiteValue.text), .text(WorkshopTime.string(a.createdAt)),
            ])
    }

    public func artifacts(_ taskID: TaskID) throws -> [Artifact] {
        try db.query("SELECT * FROM artifacts WHERE task_id=? ORDER BY created_at, id",
                     [.text(taskID.rawValue)]).map(artifactFrom)
    }

    public func artifact(_ id: String) throws -> Artifact? {
        try db.query("SELECT * FROM artifacts WHERE id=?", [.text(id)]).first.map(artifactFrom)
    }

    private func artifactFrom(_ r: Row) -> Artifact {
        Artifact(id: r["id"]!.text!, taskID: TaskID(r["task_id"]!.text!),
                 contentHash: r["content_hash"]!.text!,
                 relativePath: r["relative_path"]!.text!,
                 mime: r["mime"]?.text, producer: r["producer"]!.text!,
                 baseRevision: r["base_revision"]?.text,
                 validation: r["validation"]!.text!,
                 description: r["description"]?.text,
                 createdAt: WorkshopTime.date(r["created_at"]!.text!))
    }

    // MARK: - Usage samples

    public func insertUsageSample(taskID: TaskID, engineerID: EngineerID, provider: String,
                                  model: String?, nativeSessionID: String?, turnID: String?,
                                  sample: UsageSample, at now: Date) throws {
        try db.execute("""
            INSERT INTO usage_samples(task_id, engineer_id, provider, model, native_session_id,
                                      turn_id, input, output, cache_read, cache_write,
                                      source, observed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(taskID.rawValue), .text(engineerID.rawValue), .text(provider),
                model.map(SQLiteValue.text), nativeSessionID.map(SQLiteValue.text),
                turnID.map(SQLiteValue.text),
                sample.input.map { .integer(Int64($0)) },
                sample.output.map { .integer(Int64($0)) },
                sample.cacheRead.map { .integer(Int64($0)) },
                sample.cacheWrite.map { .integer(Int64($0)) },
                .text(sample.source), .text(WorkshopTime.string(now)),
            ])
    }

    /// Latest usage sample recorded for a task, if any.
    public func latestUsage(_ taskID: TaskID) throws -> UsageSample? {
        try db.query("""
            SELECT input, output, cache_read, cache_write, source FROM usage_samples
            WHERE task_id=? ORDER BY id DESC LIMIT 1
            """, [.text(taskID.rawValue)]).first.map { r in
                UsageSample(input: r["input"]?.int.map(Int.init),
                            output: r["output"]?.int.map(Int.init),
                            cacheRead: r["cache_read"]?.int.map(Int.init),
                            cacheWrite: r["cache_write"]?.int.map(Int.init),
                            source: r["source"]!.text!)
            }
    }

    /// All usage samples for a task, oldest first.
    public func usageSamples(_ taskID: TaskID) throws -> [UsageSampleRecord] {
        try db.query("""
            SELECT * FROM usage_samples WHERE task_id=? ORDER BY id
            """, [.text(taskID.rawValue)]).map { r in
                UsageSampleRecord(
                    taskID: taskID,
                    engineerID: EngineerID(rawValue: r["engineer_id"]!.text!) ?? .devin,
                    provider: r["provider"]!.text!,
                    model: r["model"]?.text,
                    nativeSessionID: r["native_session_id"]?.text,
                    turnID: r["turn_id"]?.text,
                    sample: UsageSample(
                        input: r["input"]?.int.map(Int.init),
                        output: r["output"]?.int.map(Int.init),
                        cacheRead: r["cache_read"]?.int.map(Int.init),
                        cacheWrite: r["cache_write"]?.int.map(Int.init),
                        source: r["source"]!.text!),
                    observedAt: WorkshopTime.date(r["observed_at"]!.text!))
            }
    }

    // MARK: - Wakeups

    public struct Wakeup {
        public let id: Int64
        public let taskID: TaskID
        public let engineerID: EngineerID
        public let reason: String
        public let triggerSeq: Int64?
        public let state: String
    }

    @discardableResult
    public func insertWakeup(taskID: TaskID, engineerID: EngineerID, reason: String,
                             triggerSeq: Int64?, state: String = "pending", at now: Date) throws -> Int64 {
        try db.execute("""
            INSERT INTO wakeups(task_id, engineer_id, reason, trigger_seq, state,
                                created_at, updated_at)
            VALUES(?,?,?,?,?,?,?)
            """, [.text(taskID.rawValue), .text(engineerID.rawValue), .text(reason),
                  triggerSeq.map(SQLiteValue.integer) ?? nil, .text(state),
                  .text(WorkshopTime.string(now)), .text(WorkshopTime.string(now))])
        return db.lastInsertRowID()
    }

    public func pendingWakeups(taskID: TaskID? = nil) throws -> [Wakeup] {
        let sql = taskID == nil
            ? "SELECT * FROM wakeups WHERE state='pending' ORDER BY id"
            : "SELECT * FROM wakeups WHERE state='pending' AND task_id=? ORDER BY id"
        let args: [SQLiteValue?] = taskID.map { [.text($0.rawValue)] } ?? []
        return try db.query(sql, args).map(wakeupFrom)
    }

    /// All wakeup rows for a task, any state, oldest first.
    public func wakeups(_ taskID: TaskID) throws -> [Wakeup] {
        try db.query("SELECT * FROM wakeups WHERE task_id=? ORDER BY id",
                     [.text(taskID.rawValue)]).map(wakeupFrom)
    }

    private func wakeupFrom(_ r: Row) -> Wakeup {
        Wakeup(id: r["id"]!.int ?? 0, taskID: TaskID(r["task_id"]!.text!),
               engineerID: EngineerID(rawValue: r["engineer_id"]!.text!) ?? .devin,
               reason: r["reason"]!.text!, triggerSeq: r["trigger_seq"]?.int,
               state: r["state"]!.text ?? "pending")
    }

    public func setWakeupState(_ id: Int64, _ state: String, at now: Date) throws {
        try db.execute("UPDATE wakeups SET state=?, updated_at=? WHERE id=?", [
            .text(state), .text(WorkshopTime.string(now)), .integer(id),
        ])
    }

    /// Consecutive engineer-triggered wakeups in a task with no intervening user
    /// message (loop bound, T11).
    public func engineerWakeupsSinceLastUserMessage(_ taskID: TaskID) throws -> Int {
        let r = try db.query("""
            SELECT COUNT(*) AS n FROM wakeups
            WHERE task_id=? AND state != 'suppressed'
              AND id > COALESCE((SELECT MAX(id) FROM wakeups w2
                                 WHERE w2.task_id=? AND w2.reason='user_message'), 0)
            """, [.text(taskID.rawValue), .text(taskID.rawValue)]).first
        return Int(r?["n"]?.int ?? 0)
    }

    // MARK: - Checkpoints

    @discardableResult
    public func insertCheckpoint(taskID: TaskID, engineerID: EngineerID, role: String,
                                 workerID: String, generation: Int, schemaVersion: Int,
                                 content: String, at now: Date) throws -> Int64 {
        try db.execute("""
            INSERT INTO checkpoints(task_id, engineer_id, role, worker_id, generation,
                                    schema_version, content, created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.text(taskID.rawValue), .text(engineerID.rawValue), .text(role),
                  .text(workerID), .integer(Int64(generation)),
                  .integer(Int64(schemaVersion)), .text(content),
                  .text(WorkshopTime.string(now))])
        return db.lastInsertRowID()
    }

    // MARK: - Session bindings

    /// Persisted (task, engineer, role, worker) → native session mapping (§6.2).
    public struct SessionBindingRecord {
        public var taskID: TaskID
        public var engineerID: EngineerID
        public var role: String
        public var workerID: String
        public var nativeSessionID: String?
        public var profileRevision: Int
        public var modelSelection: String?
        public var recoveryState: String

        public init(taskID: TaskID, engineerID: EngineerID, role: String, workerID: String,
                    nativeSessionID: String? = nil, profileRevision: Int = 1,
                    modelSelection: String? = nil, recoveryState: String = "new") {
            self.taskID = taskID
            self.engineerID = engineerID
            self.role = role
            self.workerID = workerID
            self.nativeSessionID = nativeSessionID
            self.profileRevision = profileRevision
            self.modelSelection = modelSelection
            self.recoveryState = recoveryState
        }
    }

    /// Upsert a session binding (native session id + model selection) (§6.2).
    public func saveSessionBinding(_ b: SessionBindingRecord) throws {
        try db.execute("""
            INSERT INTO session_bindings(task_id, engineer_id, role, worker_id,
                                         native_session_id, profile_revision,
                                         model_selection, recovery_state)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(task_id, engineer_id, role, worker_id) DO UPDATE SET
                native_session_id=excluded.native_session_id,
                profile_revision=excluded.profile_revision,
                model_selection=excluded.model_selection,
                recovery_state=excluded.recovery_state
            """, [.text(b.taskID.rawValue), .text(b.engineerID.rawValue), .text(b.role),
                  .text(b.workerID), b.nativeSessionID.map(SQLiteValue.text),
                  .integer(Int64(b.profileRevision)), b.modelSelection.map(SQLiteValue.text),
                  .text(b.recoveryState)])
    }

    public func sessionBinding(taskID: TaskID, engineerID: EngineerID, role: String,
                               workerID: String) throws -> SessionBindingRecord? {
        try db.query("""
            SELECT * FROM session_bindings
            WHERE task_id=? AND engineer_id=? AND role=? AND worker_id=?
            """, [.text(taskID.rawValue), .text(engineerID.rawValue), .text(role),
                  .text(workerID)]).first.map { r in
            SessionBindingRecord(
                taskID: taskID,
                engineerID: EngineerID(rawValue: r["engineer_id"]!.text!) ?? .devin,
                role: r["role"]!.text!, workerID: r["worker_id"]!.text!,
                nativeSessionID: r["native_session_id"]?.text,
                profileRevision: Int(r["profile_revision"]!.int ?? 1),
                modelSelection: r["model_selection"]?.text,
                recoveryState: r["recovery_state"]!.text!)
        }
    }

    private func outboxFrom(_ r: Row) -> OutboxEvent {
        OutboxEvent(
            seq: r["seq"]!.int ?? 0,
            taskID: r["task_id"]?.text.map { TaskID($0) },
            eventType: r["event_type"]!.text!,
            recipients: decodeList(r["recipients"]?.text),
            payload: r["payload"]!.text!,
            deliveryState: r["delivery_state"]!.text!,
            createdAt: WorkshopTime.date(r["created_at"]!.text!),
            deliveredAt: r["delivered_at"]?.text.map(WorkshopTime.date)
        )
    }

    // MARK: - JSON list helpers

    private func encodeList(_ list: [String]) -> String {
        String(data: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    private func decodeList(_ json: String?) -> [String] {
        guard let json else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
