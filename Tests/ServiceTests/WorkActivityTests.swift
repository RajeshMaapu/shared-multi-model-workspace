import XCTest
@testable import WorkshopService
@testable import WorkshopCore

final class WorkActivityTests: XCTestCase {
    func testDurableActivityIsolationPaginationAndSafeContent() async throws {
        let dir = NSTemporaryDirectory() + "workshop-activity-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        fake.script = { _ in [
            .event(.toolActivity(title: "Read file api_key=synthetic-secret", status: "in_progress", callID: "opaque-one")),
            .event(.toolActivity(title: "Read file", status: "completed", callID: "opaque-one")),
            .event(.permissionDenied("private input never stored")),
            .text("A user-visible result")
        ] }
        let path = dir + "/db.sqlite"
        let svc = try CollaborationService(databasePath: path, adapters: [fake])
        let receipt = try await svc.createTask(CreateTaskRequest(schemaVersion: 2, idempotencyKey: "activity-one", title: "Activity", objective: "Fixture", phase: .execution, participants: [], collaborationMode: .ownerOnly))
        let other = try await svc.createTask(CreateTaskRequest(schemaVersion: 2, idempotencyKey: "activity-two", title: "Other", objective: "Fixture", phase: .execution, participants: [], collaborationMode: .ownerOnly))
        await svc.start(); await svc.awaitIdle()
        let all = try await svc.readActivity(receipt.taskID)
        XCTAssertGreaterThanOrEqual(all.count, 6)
        XCTAssertTrue(all.allSatisfy { $0.taskID == receipt.taskID && $0.taskID != other.taskID })
        XCTAssertEqual(all.map(\.seq), all.map(\.seq).sorted())
        XCTAssertEqual(Set(all.map(\.seq)).count, all.count)
        let tools = all.filter { $0.kind == "tool" }
        XCTAssertEqual(tools.count, 4) // two correlated ACP events plus legacy adapter start/finish
        XCTAssertEqual(tools.filter { $0.callID == nil }.count, 2)
        XCTAssertEqual(tools[0].callID, tools[1].callID)
        XCTAssertNotEqual(tools[0].callID, "opaque-one")
        XCTAssertFalse(tools[0].title.contains("synthetic-secret"))
        XCTAssertFalse(all.contains { $0.title.contains("private input") })
        XCTAssertEqual(all.last?.kind, "lifecycle")
        XCTAssertEqual(all.last?.status, "completed")
        let page = try await svc.readActivity(receipt.taskID, limit: 2)
        let rest = try await svc.readActivity(receipt.taskID, afterSeq: page.last!.seq)
        XCTAssertEqual(page + rest, all)
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertTrue(detail.runningEngineers.isEmpty)
        await svc.shutdown()
        let reopened = try CollaborationService(databasePath: path, adapters: [], dispatcherEnabled: false)
        let replay = try await reopened.readActivity(receipt.taskID)
        XCTAssertEqual(replay, all)
        await reopened.shutdown()
    }

    func testBoundedAllowlistedActivity() {
        let item = WorkActivity(taskID: TaskID("task_test"), turnID: "turn", engineer: .devin,
            kind: "agent_thought", title: String(repeating: "x", count: 500) + "\n", status: "arbitrary raw payload", createdAt: Date())
        XCTAssertEqual(item.kind, "status")
        XCTAssertEqual(item.status, "updated")
        XCTAssertEqual(item.title.count, 240)
        XCTAssertFalse(item.title.contains("\n"))
        XCTAssertFalse(WorkActivity.safeTitle("password=synthetic-private cookie=session-private").contains("private"))
    }
}
