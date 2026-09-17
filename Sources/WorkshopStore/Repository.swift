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
                              approval_revision, report_revision, cancel_requested_at,
                              budget_policy_ref, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(task.id.rawValue), .text(task.channel), .text(task.title),
                .text(task.brief), .text(task.phase.rawValue), .text(task.state.rawValue),
                .integer(Int64(task.scopeRevision)),
                task.approvalRevision.map { .integer(Int64($0)) },
                task.reportRevision.map { .integer(Int64($0)) },
                task.cancelRequestedAt.map { .text(WorkshopTime.string($0)) },
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

    public func updateTaskPhase(_ id: TaskID, _ phase: TaskPhase, at now: Date) throws {
        try db.execute("UPDATE tasks SET phase=?, updated_at=? WHERE id=?", [
            .text(phase.rawValue), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
    }

    /// Update the research bookkeeping columns (nil = leave unchanged).
    public func updateTaskRevisions(_ id: TaskID, reportRevision: Int?? = nil,
                                    approvalRevision: Int?? = nil,
                                    cancelRequestedAt: Date?? = nil,
                                    at now: Date) throws {
        var sets: [String] = ["updated_at=?"]
        var args: [SQLiteValue?] = [.text(WorkshopTime.string(now))]
        if let reportRevision {
            sets.append("report_revision=?")
            args.append(reportRevision.map { .integer(Int64($0)) })
        }
        if let approvalRevision {
            sets.append("approval_revision=?")
            args.append(approvalRevision.map { .integer(Int64($0)) })
        }
        if let cancelRequestedAt {
            sets.append("cancel_requested_at=?")
            args.append(cancelRequestedAt.map { .text(WorkshopTime.string($0)) })
        }
        args.append(.text(id.rawValue))
        try db.execute("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id=?", args)
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
            reportRevision: r["report_revision"]?.int.map(Int.init),
            cancelRequestedAt: r["cancel_requested_at"]?.text.map(WorkshopTime.date),
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

    /// Provisional seqs (streaming placeholders) live at or above this base so
    /// they sort last while streaming and never consume a real seq slot (F1).
    public static let provisionalSeqBase: Int64 = 1_000_000_000

    public func nextMessageSeq(_ taskID: TaskID) throws -> Int64 {
        (try db.query("""
            SELECT MAX(seq) AS m FROM messages WHERE task_id=? AND seq<?
            """, [.text(taskID.rawValue), .integer(Self.provisionalSeqBase)])
            .first?["m"]?.int ?? 0) + 1
    }

    /// A provisional seq for a streaming placeholder, derived from rowid so it
    /// is unique even across concurrent streaming messages on the same task.
    public func nextProvisionalSeq() throws -> Int64 {
        Self.provisionalSeqBase
            + (try db.query("SELECT MAX(rowid) AS m FROM messages")
                .first?["m"]?.int ?? 0) + 1
    }

    /// Assign the real seq when a streaming placeholder commits (F1).
    public func reassignMessageSeq(_ id: MessageID, seq: Int64, at now: Date) throws {
        try db.execute("UPDATE messages SET seq=?, updated_at=? WHERE id=?", [
            .integer(seq), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
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

    /// Newest-page / backwards paging for T31: beforeSeq nil → newest `limit`
    /// rows; else the `limit` rows immediately before beforeSeq. Both return
    /// ascending order; provisional seqs excluded.
    public func messagePage(_ taskID: TaskID, beforeSeq: Int64? = nil,
                            limit: Int = 500) throws -> [Message] {
        let cap = min(limit, 500)
        if let beforeSeq {
            return try db.query("""
                SELECT * FROM (
                    SELECT * FROM messages
                    WHERE task_id=? AND seq<? AND seq<?
                    ORDER BY seq DESC LIMIT ?
                ) ORDER BY seq
                """, [.text(taskID.rawValue), .integer(beforeSeq),
                      .integer(Self.provisionalSeqBase),
                      .integer(Int64(cap))]).map(messageFrom)
        }
        return try db.query("""
            SELECT * FROM (
                SELECT * FROM messages
                WHERE task_id=? AND seq<?
                ORDER BY seq DESC LIMIT ?
            ) ORDER BY seq
            """, [.text(taskID.rawValue), .integer(Self.provisionalSeqBase),
                  .integer(Int64(cap))]).map(messageFrom)
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

    public func deleteMessage(_ id: MessageID) throws {
        try db.execute("DELETE FROM messages WHERE id=?", [.text(id.rawValue)])
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
                                 generation, lease_expires_at, state, risk, verification,
                                 created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(s.id.rawValue), .text(s.taskID.rawValue), .text(s.title),
                .text(encodeList(s.acceptance)), .text(encodeList(s.dependencies)),
                s.ownerID.map { .text($0.rawValue) },
                .integer(Int64(s.generation)),
                s.leaseExpiresAt.map { .text(WorkshopTime.string($0)) },
                .text(s.state.rawValue), .text(s.risk), .text(s.verification),
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

    public func updateSubtaskVerification(_ id: SubtaskID, _ verification: String,
                                          at now: Date) throws {
        try db.execute("UPDATE subtasks SET verification=?, updated_at=? WHERE id=?", [
            .text(verification), .text(WorkshopTime.string(now)), .text(id.rawValue),
        ])
    }

    /// Atomic assignment CAS: sets owner only if generation matches and the
    /// subtask is unowned (returns false otherwise).
    public func assignSubtask(_ id: SubtaskID, owner: EngineerID, expectedGeneration: Int,
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

    /// Reassignment CAS (T05): replaces the owner regardless of prior owner,
    /// bumping generation so stale results are fenced at the tool boundary.
    public func reassignSubtask(_ id: SubtaskID, newOwner: EngineerID,
                                expectedGeneration: Int, at now: Date) throws -> Bool {
        try db.execute("""
            UPDATE subtasks
            SET owner_id=?, generation=generation+1, state='claimed',
                lease_expires_at=NULL, updated_at=?
            WHERE id=? AND generation=?
            """, [
                .text(newOwner.rawValue), .text(WorkshopTime.string(now)),
                .text(id.rawValue), .integer(Int64(expectedGeneration)),
            ])
        return db.changes() == 1
    }

    /// Lease heartbeat CAS: extends the lease while owner+generation match.
    public func renewSubtaskLease(_ id: SubtaskID, owner: EngineerID, generation: Int,
                                  leaseExpiresAt: Date, at now: Date) throws -> Bool {
        try db.execute("""
            UPDATE subtasks
            SET lease_expires_at=?, updated_at=?
            WHERE id=? AND owner_id=? AND generation=?
            """, [
                .text(WorkshopTime.string(leaseExpiresAt)),
                .text(WorkshopTime.string(now)), .text(id.rawValue),
                .text(owner.rawValue), .integer(Int64(generation)),
            ])
        return db.changes() == 1
    }

    /// Subtasks whose lease has expired (lease sweeper, T05).
    public func subtasksWithExpiredLease(at now: Date) throws -> [Subtask] {
        try db.query("""
            SELECT * FROM subtasks
            WHERE lease_expires_at IS NOT NULL AND lease_expires_at < ?
              AND owner_id IS NOT NULL AND state IN ('claimed','working')
            """, [.text(WorkshopTime.string(now))]).map(subtaskFrom)
    }

    /// The original result message for (subtask, generation) — T06 idempotency.
    public func resultMessage(taskID: TaskID, subtaskID: SubtaskID,
                              generation: Int) throws -> Message? {
        let rows = try db.query("""
            SELECT * FROM messages
            WHERE task_id=? AND structured IS NOT NULL
            ORDER BY seq DESC
            """, [.text(taskID.rawValue)])
        for r in rows {
            let m = messageFrom(r)
            guard let text = m.structured,
                  let s = try? JSONDecoder().decode(JSONValue.self,
                                                    from: Data(text.utf8)),
                  s["type"]?.stringValue == "result",
                  s["subtask_id"]?.stringValue == subtaskID.rawValue,
                  s["generation"]?.intValue == Int64(generation) else { continue }
            return m
        }
        return nil
    }

    /// Wakeup rows currently marked running (wake/restart reconcile, T29).
    public func runningWakeups() throws -> [Wakeup] {
        try db.query("SELECT * FROM wakeups WHERE state='running'", [])
            .map(wakeupFrom)
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
            risk: r["risk"]?.text ?? "normal",
            verification: r["verification"]?.text ?? "none",
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

    public func insertTaskWorkspace(_ workspace: TaskWorkspace) throws {
        try db.execute("""
            INSERT INTO task_workspaces(task_id, repository_path, branch, path, base_revision, state)
            VALUES(?,?,?,?,?,?)
            """, [.text(workspace.taskID.rawValue), workspace.repositoryPath.map(SQLiteValue.text),
                  workspace.branch.map(SQLiteValue.text), .text(workspace.path),
                  workspace.baseRevision.map(SQLiteValue.text), .text(workspace.state)])
    }

    public func taskWorkspace(_ taskID: TaskID) throws -> TaskWorkspace? {
        guard let row = try db.query("SELECT * FROM task_workspaces WHERE task_id=?",
                                     [.text(taskID.rawValue)]).first else { return nil }
        return TaskWorkspace(taskID: taskID, repositoryPath: row["repository_path"]?.text,
                             branch: row["branch"]?.text, path: row["path"]!.text!,
                             baseRevision: row["base_revision"]?.text, state: row["state"]!.text!)
    }

    public func insertTaskIngress(taskID: TaskID, request: CreateTaskRequest,
                                  principal: String) throws {
        let requestJSON = String(decoding: try JSONEncoder().encode(request),
                                 as: UTF8.self)
        var sourceTaskID: SQLiteValue?
        var invocationID: SQLiteValue?
        if let origin = request.origin {
            sourceTaskID = SQLiteValue.text(origin.sourceTaskID)
            invocationID = SQLiteValue.text(origin.invocationID)
        }
        try db.execute("""
            INSERT INTO task_ingress(task_id, principal, request_json,
                                     source_task_id, invocation_id,
                                     last_acknowledged_seq)
            VALUES(?,?,?,?,?,0)
            """, [
                .text(taskID.rawValue), .text(principal), .text(requestJSON),
                sourceTaskID, invocationID,
            ])
    }

    public func taskIngress(_ taskID: TaskID) throws -> TaskIngress? {
        guard let row = try db.query("""
            SELECT request_json, principal, last_acknowledged_seq FROM task_ingress
            WHERE task_id=?
            """, [.text(taskID.rawValue)]).first else { return nil }
        let request = try JSONDecoder().decode(CreateTaskRequest.self,
                                               from: Data(row["request_json"]!.text!.utf8))
        return TaskIngress(request: request, source: row["principal"]!.text!,
                           lastAcknowledgedSeq: row["last_acknowledged_seq"]!.int ?? 0)
    }

    public func taskIDForOrigin(principal: String, sourceTaskID: String,
                                invocationID: String) throws -> TaskID? {
        try db.query("""
            SELECT task_id FROM task_ingress
            WHERE principal=? AND source_task_id=? AND invocation_id=?
            """, [.text(principal), .text(sourceTaskID), .text(invocationID)])
            .first?["task_id"]?.text.map { TaskID($0) }
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

    public func workActivity(taskID: TaskID, afterSeq: Int64, limit: Int) throws -> [WorkActivity] {
        try db.query("SELECT * FROM outbox WHERE task_id=? AND event_type='work.activity' AND seq>? ORDER BY seq LIMIT ?",
          [.text(taskID.rawValue), .integer(afterSeq), .integer(Int64(limit))]).map(outboxFrom).compactMap { row in
            guard var activity = try? JSONDecoder().decode(WorkActivity.self, from: Data(row.payload.utf8)) else { return nil }
            activity.seq = row.seq
            return activity
        }
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
                                  base_revision, validation, description, generation,
                                  created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(a.id), .text(a.taskID.rawValue), .text(a.contentHash),
                .text(a.relativePath), a.mime.map(SQLiteValue.text), .text(a.producer),
                a.baseRevision.map(SQLiteValue.text), .text(a.validation),
                a.description.map(SQLiteValue.text),
                a.generation.map { SQLiteValue.integer(Int64($0)) },
                .text(WorkshopTime.string(a.createdAt)),
            ])
    }

    /// T06: dedupe artifacts on (task, content_hash).
    public func artifactByHash(taskID: TaskID, contentHash: String) throws -> Artifact? {
        try db.query("""
            SELECT * FROM artifacts WHERE task_id=? AND content_hash=?
            ORDER BY created_at LIMIT 1
            """, [.text(taskID.rawValue), .text(contentHash)]).first.map(artifactFrom)
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
                 generation: r["generation"]?.int.map(Int.init),
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

    /// Suppress every pending wakeup on a task (pause/cancel).
    public func suppressPendingWakeups(_ taskID: TaskID, at now: Date) throws {
        try db.execute("""
            UPDATE wakeups SET state='suppressed', updated_at=?
            WHERE task_id=? AND state='pending'
            """, [.text(WorkshopTime.string(now)), .text(taskID.rawValue)])
    }

    // MARK: - Proposals / Reports / Decisions (Phase 3)

    public func upsertProposal(_ p: Proposal) throws {
        try db.execute("""
            INSERT INTO proposals(id, task_id, author, revision, visibility, content,
                                  created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,
                visibility=excluded.visibility, content=excluded.content,
                updated_at=excluded.updated_at
            """, [.text(p.id), .text(p.taskID.rawValue), .text(p.author.rawValue),
                  .integer(Int64(p.revision)), .text(p.visibility), .text(p.content),
                  .text(WorkshopTime.string(p.createdAt)),
                  .text(WorkshopTime.string(p.updatedAt))])
    }

    public func proposals(_ taskID: TaskID) throws -> [Proposal] {
        try db.query("SELECT * FROM proposals WHERE task_id=? ORDER BY created_at, id",
                     [.text(taskID.rawValue)]).map(proposalFrom)
    }

    public func proposal(_ id: String) throws -> Proposal? {
        try db.query("SELECT * FROM proposals WHERE id=?", [.text(id)])
            .first.map(proposalFrom)
    }

    public func proposalBy(taskID: TaskID, author: EngineerID) throws -> Proposal? {
        try db.query("""
            SELECT * FROM proposals WHERE task_id=? AND author=?
            ORDER BY revision DESC LIMIT 1
            """, [.text(taskID.rawValue), .text(author.rawValue)]).first.map(proposalFrom)
    }

    /// Publish every draft on the task in one go (called inside a transaction).
    public func publishAllProposals(_ taskID: TaskID, at now: Date) throws {
        try db.execute("""
            UPDATE proposals SET visibility='published', updated_at=?
            WHERE task_id=? AND visibility='draft'
            """, [.text(WorkshopTime.string(now)), .text(taskID.rawValue)])
    }

    private func proposalFrom(_ r: Row) -> Proposal {
        Proposal(id: r["id"]!.text!, taskID: TaskID(r["task_id"]!.text!),
                 author: EngineerID(rawValue: r["author"]!.text!) ?? .devin,
                 revision: Int(r["revision"]!.int ?? 1),
                 visibility: r["visibility"]!.text!, content: r["content"]!.text!,
                 createdAt: WorkshopTime.date(r["created_at"]!.text!),
                 updatedAt: WorkshopTime.date(r["updated_at"]!.text!))
    }

    public func insertReport(_ rep: Report) throws {
        try db.execute("""
            INSERT INTO reports(id, task_id, revision, author, content, created_at)
            VALUES(?,?,?,?,?,?)
            """, [.text(rep.id), .text(rep.taskID.rawValue), .integer(Int64(rep.revision)),
                  .text(rep.author), .text(rep.content),
                  .text(WorkshopTime.string(rep.createdAt))])
    }

    public func reports(_ taskID: TaskID) throws -> [Report] {
        try db.query("SELECT * FROM reports WHERE task_id=? ORDER BY revision",
                     [.text(taskID.rawValue)]).map(reportFrom)
    }

    public func latestReport(_ taskID: TaskID) throws -> Report? {
        try db.query("""
            SELECT * FROM reports WHERE task_id=? ORDER BY revision DESC LIMIT 1
            """, [.text(taskID.rawValue)]).first.map(reportFrom)
    }

    private func reportFrom(_ r: Row) -> Report {
        Report(id: r["id"]!.text!, taskID: TaskID(r["task_id"]!.text!),
               revision: Int(r["revision"]!.int ?? 1), author: r["author"]!.text!,
               content: r["content"]!.text!,
               createdAt: WorkshopTime.date(r["created_at"]!.text!))
    }

    public func insertDecision(_ d: Decision) throws {
        try db.execute("""
            INSERT INTO decisions(id, task_id, kind, revision, scope, author, body,
                                  related_id, created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(d.id), .text(d.taskID.rawValue), .text(d.kind),
                  d.revision.map { .integer(Int64($0)) },
                  d.scope.map(SQLiteValue.text), .text(d.author), .text(d.body),
                  d.relatedID.map(SQLiteValue.text),
                  .text(WorkshopTime.string(d.createdAt))])
    }

    public func decisions(_ taskID: TaskID) throws -> [Decision] {
        try db.query("SELECT * FROM decisions WHERE task_id=? ORDER BY created_at, id",
                     [.text(taskID.rawValue)]).map(decisionFrom)
    }

    private func decisionFrom(_ r: Row) -> Decision {
        Decision(id: r["id"]!.text!, taskID: TaskID(r["task_id"]!.text!),
                 kind: r["kind"]!.text!, revision: r["revision"]?.int.map(Int.init),
                 scope: r["scope"]?.text, author: r["author"]!.text!,
                 body: r["body"]!.text!, relatedID: r["related_id"]?.text,
                 createdAt: WorkshopTime.date(r["created_at"]!.text!))
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

    // MARK: - Quota snapshots (§10)

    public func insertQuotaSnapshot(_ s: QuotaSnapshot) throws {
        try db.execute("""
            INSERT INTO quota_snapshots(bucket, remaining, unit, reset_at, source,
                                        observed_at, availability)
            VALUES(?,?,?,?,?,?,?)
            """, [.text(s.bucket), .text(s.remaining),
                  s.unit.map(SQLiteValue.text),
                  s.resetAt.map { .text(WorkshopTime.string($0)) },
                  .text(s.source), .text(WorkshopTime.string(s.observedAt)),
                  .text(s.availability)])
    }

    public func quotaSnapshots(bucket: String? = nil) throws -> [QuotaSnapshot] {
        let sql = bucket == nil
            ? "SELECT * FROM quota_snapshots ORDER BY id"
            : "SELECT * FROM quota_snapshots WHERE bucket=? ORDER BY id"
        let args: [SQLiteValue?] = bucket.map { [.text($0)] } ?? []
        return try db.query(sql, args).map(quotaSnapshotFrom)
    }

    public func latestQuotaSnapshot(_ bucket: String) throws -> QuotaSnapshot? {
        try db.query("""
            SELECT * FROM quota_snapshots WHERE bucket=? ORDER BY id DESC LIMIT 1
            """, [.text(bucket)]).first.map(quotaSnapshotFrom)
    }

    private func quotaSnapshotFrom(_ r: Row) -> QuotaSnapshot {
        QuotaSnapshot(id: r["id"]!.int!, bucket: r["bucket"]!.text!,
                      remaining: r["remaining"]!.text!, unit: r["unit"]?.text,
                      resetAt: r["reset_at"]?.text.map(WorkshopTime.date),
                      source: r["source"]!.text!,
                      observedAt: WorkshopTime.date(r["observed_at"]!.text!),
                      availability: r["availability"]!.text!)
    }

    /// Today's committed token usage (input+output+cache) for an engineer, plus
    /// whether any sample had nil counters (which makes remaining "unknown").
    public func usageToday(_ engineerID: EngineerID, on dayStart: Date) throws
        -> (tokens: Int, hasUnknown: Bool) {
        let rows = try db.query("""
            SELECT input, output, cache_read, cache_write FROM usage_samples
            WHERE engineer_id=? AND observed_at>=?
            """, [.text(engineerID.rawValue), .text(WorkshopTime.string(dayStart))])
        var total = 0
        var unknown = false
        for r in rows {
            let parts = [r["input"]?.int, r["output"]?.int,
                         r["cache_read"]?.int, r["cache_write"]?.int]
            if parts.contains(where: { $0 == nil }) { unknown = true }
            total += Int(parts.compactMap { $0 }.reduce(0, +))
        }
        return (total, unknown)
    }

    // MARK: - Reservations (§10)

    public func insertReservation(_ r: Reservation) throws {
        try db.execute("""
            INSERT INTO reservations(id, task_id, engineer_id, bucket, reserved,
                                     committed, state, expires_at, created_at)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(r.id), .text(r.taskID.rawValue), .text(r.engineerID.rawValue),
                  .text(r.bucket), .integer(Int64(r.reserved)),
                  r.committed.map { SQLiteValue.integer(Int64($0)) },
                  .text(r.state), .text(WorkshopTime.string(r.expiresAt)),
                  .text(WorkshopTime.string(r.createdAt))])
    }

    public func updateReservation(_ id: String, state: String, committed: Int?,
                                  at now: Date) throws {
        try db.execute("""
            UPDATE reservations SET state=?, committed=COALESCE(?, committed)
            WHERE id=?
            """, [.text(state), committed.map { SQLiteValue.integer(Int64($0)) },
                  .text(id)])
    }

    public func reservations(taskID: TaskID? = nil, state: String? = nil) throws
        -> [Reservation] {
        var sql = "SELECT * FROM reservations"
        var args: [SQLiteValue?] = []
        var clauses: [String] = []
        if let taskID { clauses.append("task_id=?"); args.append(.text(taskID.rawValue)) }
        if let state { clauses.append("state=?"); args.append(.text(state)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY created_at"
        return try db.query(sql, args).map(reservationFrom)
    }

    /// Sum of held reservations against a bucket (T13: never oversubscribe).
    public func heldReservationTotal(_ bucket: String) throws -> Int {
        let r = try db.query("""
            SELECT COALESCE(SUM(reserved), 0) AS total FROM reservations
            WHERE bucket=? AND state='held'
            """, [.text(bucket)])
        return Int(r.first?["total"]?.int ?? 0)
    }

    private func reservationFrom(_ r: Row) -> Reservation {
        Reservation(id: r["id"]!.text!, taskID: TaskID(r["task_id"]!.text!),
                    engineerID: EngineerID(rawValue: r["engineer_id"]!.text!) ?? .devin,
                    bucket: r["bucket"]!.text!, reserved: Int(r["reserved"]!.int!),
                    committed: r["committed"]?.int.map(Int.init),
                    state: r["state"]!.text!,
                    expiresAt: WorkshopTime.date(r["expires_at"]!.text!),
                    createdAt: WorkshopTime.date(r["created_at"]!.text!))
    }

    // MARK: - Resource leases (§9.2, T24)

    public func lease(_ resource: String) throws -> ResourceLease? {
        try db.query("SELECT * FROM leases WHERE resource=?",
                     [.text(resource)]).first.map(leaseFrom)
    }

    public func leases() throws -> [ResourceLease] {
        try db.query("SELECT * FROM leases ORDER BY resource").map(leaseFrom)
    }

    /// CAS insert-or-takeover: succeeds when no row exists or the existing
    /// lease is expired; bumps generation on takeover.
    @discardableResult
    public func acquireLease(resource: String, owner: String, taskID: TaskID?,
                             ttlSeconds: Int, url: String?, at now: Date) throws
        -> ResourceLease? {
        let existing = try lease(resource)
        if let existing, !existing.expired(at: now) {
            return nil
        }
        let generation = (existing?.generation ?? 0) + 1
        try db.execute("""
            INSERT INTO leases(resource, owner, task_id, generation, expires_at, url,
                               updated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(resource) DO UPDATE SET owner=excluded.owner,
                task_id=excluded.task_id, generation=excluded.generation,
                expires_at=excluded.expires_at, url=excluded.url,
                updated_at=excluded.updated_at
            """, [.text(resource), .text(owner),
                  taskID.map { .text($0.rawValue) }, .integer(Int64(generation)),
                  .text(WorkshopTime.string(now + TimeInterval(ttlSeconds))),
                  url.map(SQLiteValue.text), .text(WorkshopTime.string(now))])
        return try lease(resource)
    }

    /// CAS renew: only the live owner at the current generation may extend.
    @discardableResult
    public func renewLease(resource: String, owner: String, generation: Int,
                           ttlSeconds: Int, at now: Date) throws -> Bool {
        guard let existing = try lease(resource),
              existing.owner == owner, existing.generation == generation,
              !existing.expired(at: now) else { return false }
        try db.execute("""
            UPDATE leases SET expires_at=?, updated_at=? WHERE resource=?
            """, [.text(WorkshopTime.string(now + TimeInterval(ttlSeconds))),
                  .text(WorkshopTime.string(now)), .text(resource)])
        return true
    }

    /// CAS release: only the live owner at the current generation may release.
    @discardableResult
    public func releaseLease(resource: String, owner: String, generation: Int,
                             at now: Date) throws -> Bool {
        guard let existing = try lease(resource),
              existing.owner == owner, existing.generation == generation else {
            return false
        }
        try db.execute("DELETE FROM leases WHERE resource=?", [.text(resource)])
        return true
    }

    private func leaseFrom(_ r: Row) -> ResourceLease {
        ResourceLease(resource: r["resource"]!.text!, owner: r["owner"]!.text!,
                      taskID: r["task_id"]?.text.map { TaskID($0) },
                      generation: Int(r["generation"]!.int!),
                      expiresAt: WorkshopTime.date(r["expires_at"]!.text!),
                      url: r["url"]?.text,
                      updatedAt: WorkshopTime.date(r["updated_at"]!.text!))
    }

    // MARK: - Outbox cursors (§8.5)

    public func setOutboxCursor(_ consumer: String, seq: Int64, at now: Date) throws {
        try db.execute("""
            INSERT INTO outbox_cursors(consumer, last_seq, updated_at) VALUES(?,?,?)
            ON CONFLICT(consumer) DO UPDATE SET last_seq=excluded.last_seq,
                updated_at=excluded.updated_at
            """, [.text(consumer), .integer(seq), .text(WorkshopTime.string(now))])
    }

    public func outboxCursor(_ consumer: String) throws -> Int64 {
        try db.query("SELECT last_seq FROM outbox_cursors WHERE consumer=?",
                     [.text(consumer)]).first?["last_seq"]?.int ?? 0
    }

    // MARK: - Turns (T05/T23/T29, §14.5)

    public func insertTurn(_ t: Turn) throws {
        try db.execute("""
            INSERT INTO turns(id, task_id, subtask_id, engineer_id, generation, state,
                              started_at, first_event_at, ended_at, native_session_id,
                              request_ids)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(t.id), .text(t.taskID.rawValue),
                  t.subtaskID.map { .text($0.rawValue) },
                  .text(t.engineerID.rawValue),
                  t.generation.map { SQLiteValue.integer(Int64($0)) },
                  .text(t.state), .text(WorkshopTime.string(t.startedAt)),
                  t.firstEventAt.map { .text(WorkshopTime.string($0)) },
                  t.endedAt.map { .text(WorkshopTime.string($0)) },
                  t.nativeSessionID.map(SQLiteValue.text),
                  .text(encodeList(t.requestIDs))])
    }

    public func updateTurnState(_ id: String, _ state: String, at now: Date) throws {
        try db.execute("""
            UPDATE turns SET state=?, ended_at=CASE
                WHEN ? IN ('completed','failed','cancelled','interrupted','uncertain')
                THEN ? ELSE ended_at END WHERE id=?
            """, [.text(state), .text(state), .text(WorkshopTime.string(now)),
                  .text(id)])
    }

    public func markTurnFirstEvent(_ id: String, at now: Date) throws {
        try db.execute("""
            UPDATE turns SET first_event_at=COALESCE(first_event_at, ?) WHERE id=?
            """, [.text(WorkshopTime.string(now)), .text(id)])
    }

    public func turn(_ id: String) throws -> Turn? {
        try db.query("SELECT * FROM turns WHERE id=?", [.text(id)])
            .first.map(turnFrom)
    }

    public func turns(taskID: TaskID? = nil, state: String? = nil) throws -> [Turn] {
        var sql = "SELECT * FROM turns"
        var args: [SQLiteValue?] = []
        var clauses: [String] = []
        if let taskID { clauses.append("task_id=?"); args.append(.text(taskID.rawValue)) }
        if let state { clauses.append("state=?"); args.append(.text(state)) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY started_at"
        return try db.query(sql, args).map(turnFrom)
    }

    private func turnFrom(_ r: Row) -> Turn {
        Turn(id: r["id"]!.text!, taskID: TaskID(r["task_id"]!.text!),
             subtaskID: r["subtask_id"]?.text.map { SubtaskID($0) },
             engineerID: EngineerID(rawValue: r["engineer_id"]!.text!) ?? .devin,
             generation: r["generation"]?.int.map(Int.init),
             state: r["state"]!.text!,
             startedAt: WorkshopTime.date(r["started_at"]!.text!),
             firstEventAt: r["first_event_at"]?.text.map(WorkshopTime.date),
             endedAt: r["ended_at"]?.text.map(WorkshopTime.date),
             nativeSessionID: r["native_session_id"]?.text,
             requestIDs: decodeList(r["request_ids"]?.text))
    }

    // MARK: - Checkpoint queries (§6.3, T30)

    /// Latest checkpoint row for an owner, any validity.
    public func latestCheckpoint(taskID: TaskID, engineerID: EngineerID)
        throws -> (id: Int64, generation: Int, schemaVersion: Int, content: String,
                   valid: Bool, createdAt: Date)? {
        try db.query("""
            SELECT * FROM checkpoints WHERE task_id=? AND engineer_id=?
            ORDER BY id DESC LIMIT 1
            """, [.text(taskID.rawValue), .text(engineerID.rawValue)])
            .first.map(checkpointFrom)
    }

    /// Latest *valid* checkpoint — what resume actually uses.
    public func latestValidCheckpoint(taskID: TaskID, engineerID: EngineerID)
        throws -> (id: Int64, generation: Int, schemaVersion: Int, content: String,
                   valid: Bool, createdAt: Date)? {
        try db.query("""
            SELECT * FROM checkpoints WHERE task_id=? AND engineer_id=? AND valid=1
            ORDER BY id DESC LIMIT 1
            """, [.text(taskID.rawValue), .text(engineerID.rawValue)])
            .first.map(checkpointFrom)
    }

    public func markCheckpointInvalid(_ id: Int64) throws {
        try db.execute("UPDATE checkpoints SET valid=0 WHERE id=?", [.integer(id)])
    }

    private func checkpointFrom(_ r: Row)
        -> (id: Int64, generation: Int, schemaVersion: Int, content: String,
            valid: Bool, createdAt: Date) {
        (id: r["id"]!.int!, generation: Int(r["generation"]!.int!),
         schemaVersion: Int(r["schema_version"]!.int!),
         content: r["content"]!.text!, valid: (r["valid"]?.int ?? 1) == 1,
         createdAt: WorkshopTime.date(r["created_at"]!.text!))
    }
}
