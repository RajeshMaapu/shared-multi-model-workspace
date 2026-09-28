import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-E3 (turn summaries) and G-E4 (work.activity outbox pruning).
final class TurnSummaryTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-ts-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(adapters: [FakeAdapter], dbPath: String)
        throws -> CollaborationService {
        let svc = try CollaborationService(
            databasePath: dbPath, adapters: adapters, dispatcherEnabled: false,
            homeDir: dir, wakeupCoalescence: .zero,
            wakeupRetryBackoff: [.milliseconds(50), .milliseconds(50),
                                 .milliseconds(50)],
            researchDeadline: 0, reviewDeadline: 0)
        for adapter in adapters {
            adapter.toolRunner = { [weak svc] name, args, principal in
                guard let svc else { return .null }
                return try await svc.callTool(name, args: args, principal: principal)
            }
        }
        return svc
    }

    private func task(_ svc: CollaborationService) async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "obj",
            phase: .execution, participants: [.devin, .kimi]))
        return receipt.taskID
    }

    // MARK: - G-E3 turn summaries

    /// A turn that posts via tools AND streams text stores the stream as a
    /// turn_summary: excluded from default reads, packets and wakeups.
    func testTurnSummaryLifecycle() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let kimi = adapters.first { $0.engineer == .kimi }!
        let dbPath = dir + "/sum.sqlite"
        let svc = try makeService(adapters: adapters, dbPath: dbPath)
        devin.script = { context in
            [.toolCall("workshop_post_message", .object([
                "task_id": .string(context.task.id.rawValue),
                "body": .string("posted through tools"),
                "kind": .string("text")])),
             .text("@kimi this is the streamed recap")]
        }
        let taskID = try await task(svc)
        await svc.start()
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)

        let all = try await svc.readMessages(taskID, includeSummaries: true)
        let devinMsgs = all.filter { $0.author == .engineer(.devin) }
        XCTAssertEqual(devinMsgs.filter { $0.kind == .text }.count, 1)
        let summaries = devinMsgs.filter { $0.kind == .turnSummary }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].body.contains("@kimi"))

        // Default reads exclude the summary; opt-in includes it.
        let def = try await svc.readMessages(taskID)
        XCTAssertTrue(def.allSatisfy { $0.kind != .turnSummary })
        let page = try await svc.readMessagePage(taskID)
        XCTAssertTrue(page.allSatisfy { $0.kind != .turnSummary })
        let pageAll = try await svc.readMessagePage(taskID,
                                                    includeSummaries: true)
        XCTAssertTrue(pageAll.contains { $0.kind == .turnSummary })
        let toolRead = try await svc.toolReadMessages(
            taskID: taskID, afterSeq: 0, limit: 50, principal: .engineer(.kimi))
        XCTAssertTrue(toolRead.allSatisfy { $0.kind != .turnSummary })
        let toolReadAll = try await svc.toolReadMessages(
            taskID: taskID, afterSeq: 0, limit: 50, includeSummaries: true,
            principal: .engineer(.kimi))
        XCTAssertTrue(toolReadAll.contains { $0.kind == .turnSummary })

        // A peer's packet never contains the summary body.
        await svc.runTurnForTest(engineer: .kimi, taskID: taskID)
        let peerPacket = kimi.receivedContexts.last!.packetText(for: .kimi)
        XCTAssertFalse(peerPacket.contains("streamed recap"))

        // A "@kimi" inside a summary produces no wakeup.
        let db = try Database(path: dbPath)
        let wakeups = try db.query(
            "SELECT COUNT(*) AS c FROM wakeups WHERE task_id=? AND engineer_id='kimi'",
            [.text(taskID.rawValue)]).first?["c"]?.int ?? 0
        XCTAssertEqual(wakeups, 0)
        await svc.shutdown()
    }

    /// A streamed-only turn (no tool posts) stays a plain text message.
    func testStreamedOnlyTurnStaysText() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let svc = try makeService(adapters: adapters, dbPath: dir + "/t.sqlite")
        devin.script = { _ in [.text("just a reply")] }
        let taskID = try await task(svc)
        await svc.start()
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        let msgs = try await svc.readMessages(taskID, includeSummaries: true)
            .filter { $0.author == .engineer(.devin) }
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].kind, .text)
        await svc.shutdown()
    }

    /// Engineers cannot fabricate a turn_summary via workshop_post_message.
    func testToolPostRejectsTurnSummaryKind() async throws {
        let adapters = fakes()
        let svc = try makeService(adapters: adapters, dbPath: dir + "/k.sqlite")
        let taskID = try await task(svc)
        await svc.start()
        do {
            _ = try await svc.toolPostMessage(
                taskID: taskID, body: "fake summary", kind: "turn_summary",
                replyTo: nil, principal: .engineer(.devin))
            XCTFail("turn_summary kind must be rejected")
        } catch {}
        await svc.shutdown()
    }

    // MARK: - G-E4 work.activity pruning

    func testPruneWorkActivityKeepsNewestPerTask() throws {
        let dbPath = dir + "/prune.sqlite"
        let db = try Database(path: dbPath)
        try Migrations.all.migrate(db)
        let repo = WorkshopRepository(db: db)
        let a = TaskID("task_a"), b = TaskID("task_b")
        let t = Date()
        // Foreign keys: tasks must exist.
        let ts = WorkshopTime.string(t)
        for id in [a, b] {
            try db.execute("""
                INSERT INTO tasks(id,channel,title,brief,phase,state,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?)
                """, [.text(id.rawValue), .text("main"), .text("t"),
                      .text("b"), .text("execution"), .text("working"),
                      .text(ts), .text(ts)])
        }
        for _ in 0..<600 {
            _ = try repo.insertOutbox(taskID: a, eventType: "work.activity",
                                      payload: "{}", deliveryState: "delivered", at: t)
        }
        for _ in 0..<50 {
            _ = try repo.insertOutbox(taskID: b, eventType: "work.activity",
                                      payload: "{}", deliveryState: "delivered", at: t)
        }
        _ = try repo.insertOutbox(taskID: a, eventType: "message.committed",
                                  payload: "{}", deliveryState: "delivered", at: t)
        _ = try repo.insertOutbox(taskID: a, eventType: "dispatch.requested",
                                  payload: "{}", deliveryState: "pending", at: t)
        // One pending activity row must survive too.
        _ = try repo.insertOutbox(taskID: a, eventType: "work.activity",
                                  payload: "{}", deliveryState: "pending", at: t)

        let deleted = try repo.pruneWorkActivity(taskID: a, keep: 200)
        XCTAssertEqual(deleted, 400)
        let remainingA = try db.query("""
            SELECT COUNT(*) AS c FROM outbox
            WHERE task_id=? AND event_type='work.activity' AND delivery_state='delivered'
            """, [.text(a.rawValue)]).first?["c"]?.int
        XCTAssertEqual(remainingA, 200)
        // Kept rows are the newest 200.
        let oldestKept = try db.query("""
            SELECT MIN(seq) AS s FROM outbox
            WHERE task_id=? AND event_type='work.activity' AND delivery_state='delivered'
            """, [.text(a.rawValue)]).first?["s"]?.int
        XCTAssertEqual(oldestKept, 401)
        let remainingB = try db.query("""
            SELECT COUNT(*) AS c FROM outbox
            WHERE task_id=? AND event_type='work.activity'
            """, [.text(b.rawValue)]).first?["c"]?.int
        XCTAssertEqual(remainingB, 50)
        let others = try db.query("""
            SELECT COUNT(*) AS c FROM outbox
            WHERE task_id=? AND event_type != 'work.activity'
            """, [.text(a.rawValue)]).first?["c"]?.int
        XCTAssertEqual(others, 2)
        let pendingAct = try db.query("""
            SELECT COUNT(*) AS c FROM outbox
            WHERE task_id=? AND event_type='work.activity' AND delivery_state='pending'
            """, [.text(a.rawValue)]).first?["c"]?.int
        XCTAssertEqual(pendingAct, 1)
    }
}
