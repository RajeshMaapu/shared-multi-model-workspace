import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-D9 restart soak: ten abrupt service restarts against one on-disk DB.
/// Each iteration leaves a stalled owner turn and a peer wakeup mid-flight;
/// the next service's startup reconcile must recover both without losing or
/// duplicating wakeups.
final class RestartSoakTests: XCTestCase {
    var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "/soak-" + UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func stalled(_ engineer: EngineerID) -> FakeAdapter {
        let fake = FakeAdapter(engineer: engineer, delayPerDelta: .zero)
        fake.script = { context in
            [.toolCall("workshop_post_message", .object([
                "task_id": .string(context.task.id.rawValue),
                "body": .string("iteration message")])),
             .stall]
        }
        return fake
    }

    func testTenAbruptRestartsRecoverCleanly() async throws {
        let dbPath = dir + "/workshop.sqlite"
        var services: [CollaborationService] = []
        let overall = Date().addingTimeInterval(60)
        for iteration in 0..<10 {
            let devin = stalled(.devin)
            let kimi = stalled(.kimi)
            let service = try CollaborationService(
                databasePath: dbPath,
                adapters: [devin, kimi,
                           FakeAdapter(engineer: .deepseek, delayPerDelta: .zero)],
                dispatcherEnabled: true, homeDir: dir,
                wakeupCoalescence: .milliseconds(20))
            devin.toolRunner = { name, args, principal in
                try await service.callTool(name, args: args, principal: principal)
            }
            kimi.toolRunner = { name, args, principal in
                try await service.callTool(name, args: args, principal: principal)
            }
            await service.start()
            _ = try await service.createTask(CreateTaskRequest(
                schemaVersion: 2, idempotencyKey: "soak-\(iteration)",
                title: "Soak \(iteration)", objective: "stall",
                phase: .execution, participants: [.kimi],
                collaborationMode: .requestedPeers), principal: .user)
            // Wait until both turns are actually running before killing them.
            let deadline = Date().addingTimeInterval(5)
            while (devin.turnCount == 0 || kimi.turnCount == 0),
                  Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(devin.turnCount, 0,
                                 "iteration \(iteration): owner turn never started")
            XCTAssertGreaterThan(kimi.turnCount, 0,
                                 "iteration \(iteration): peer turn never started")
            // Abrupt shutdown: do not wait for the stalled turns.
            await service.shutdown()
            services.append(service)
            XCTAssertLessThan(Date(), overall, "soak exceeded 60 s budget")
        }

        // One final service start runs reconcile on the last stalled turns.
        let finalService = try CollaborationService(
            databasePath: dbPath,
            adapters: [FakeAdapter(engineer: .devin, delayPerDelta: .zero),
                       FakeAdapter(engineer: .kimi, delayPerDelta: .zero),
                       FakeAdapter(engineer: .deepseek, delayPerDelta: .zero)],
            dispatcherEnabled: true, homeDir: dir)
        await finalService.start()
        let repo = WorkshopRepository(db: try Database(path: dbPath))
        // Every wakeup is terminal or pending; none stuck 'running'.
        let states = try repo.db.query(
            "SELECT state,COUNT(*) c FROM wakeups GROUP BY state")
        let allowed: Set<String> = ["done", "silent", "launch_failed",
                                    "failed", "suppressed", "pending"]
        var total = 0
        for row in states {
            let state = row["state"]?.text ?? ""
            XCTAssertTrue(allowed.contains(state), "unexpected wakeup state \(state)")
            total += row["c"]?.int.map(Int.init) ?? 0
        }
        XCTAssertGreaterThanOrEqual(total, 10)
        // No duplicate pending wakeup for the same
        // (task, engineer, reason, trigger_seq).
        let dupes = try repo.db.query("""
            SELECT task_id,engineer_id,reason,trigger_seq,COUNT(*) c
            FROM wakeups WHERE state='pending'
            GROUP BY task_id,engineer_id,reason,trigger_seq HAVING c>1
            """)
        XCTAssertEqual(dupes.count, 0)
        // No message remains 'streaming'.
        let streaming = try repo.db.query(
            "SELECT COUNT(*) c FROM messages WHERE delivery_state='streaming'")
        XCTAssertEqual(streaming.first?["c"]?.int.map(Int.init), 0)
        // Each interrupted turn that owned a subtask leaves exactly one
        // recovery system event ("no valid checkpoint" for these fakes).
        let interruptedOwned = try repo.db.query("""
            SELECT COUNT(*) c FROM turns
            WHERE state='interrupted' AND subtask_id IS NOT NULL
            """)
        let ownedCount = interruptedOwned.first?["c"]?.int.map(Int.init) ?? 0
        let events = try repo.db.query("""
            SELECT COUNT(*) c FROM messages WHERE kind='system_event' AND (
                body LIKE '%from checkpoint%'
                OR body LIKE '%no valid checkpoint%')
            """)
        XCTAssertEqual(events.first?["c"]?.int.map(Int.init), ownedCount,
                       "each interrupted owned turn leaves one recovery trail")
        XCTAssertGreaterThanOrEqual(ownedCount, 10)
        _ = services // keep services alive through the assertions
    }
}
