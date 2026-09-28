import XCTest
@testable import WorkshopCore
@testable import WorkshopService
@testable import WorkshopStore

final class RevisionRecoveryTests: XCTestCase {
    private func waitFor(_ timeout: TimeInterval = 10,
                         _ cond: @escaping () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await cond()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A failed owner launch is retried with bounded backoff; at exhaustion
    /// the owned subtask and the task block with the generation preserved,
    /// and resumeTask re-dispatches once the adapter is healthy again.
    func testExhaustedOwnerStartupBlocksAndResumeRedispatches() async throws {
        let root = "/private/tmp/startup-recovery-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let devin = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        devin.openSessionError = WorkshopError.invalidRequest("startup unavailable")
        let service = try CollaborationService(databasePath: root + "/test.sqlite",
            adapters: [devin], dispatcherEnabled: true, homeDir: root,
            wakeupCoalescence: .zero,
            wakeupRetryBackoff: [.milliseconds(20), .milliseconds(20),
                                 .milliseconds(20)])
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "Startup", objective: "Test",
            phase: .execution, participants: [.devin]))
        await service.start()
        // Wait for the dispatch claim before capturing the generation.
        _ = await waitFor {
            try await service.getTask(receipt.taskID).subtasks[0].ownerID != nil }
        let before = try await service.getTask(receipt.taskID)
        let blocked = await waitFor {
            try await service.getTask(receipt.taskID).task.state == .blocked }
        XCTAssertTrue(blocked)
        let after = try await service.getTask(receipt.taskID)
        XCTAssertEqual(after.subtasks[0].state, .blocked)
        XCTAssertEqual(after.subtasks[0].ownerID, .devin)
        XCTAssertEqual(after.subtasks[0].generation, before.subtasks[0].generation)
        var messages = try await service.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains {
            $0.body.contains("Owner startup failed before execution") })
        XCTAssertFalse(messages.contains { $0.body.contains("Lease for") })
        let wakeups = try await service.wakeupsForTest(receipt.taskID)
        XCTAssertTrue(wakeups.contains { $0.state == "launch_failed" })

        // A healthy adapter plus a resume re-dispatches the owner.
        devin.openSessionError = nil
        try await service.resumeTask(taskID: receipt.taskID, principal: .user)
        let ran = await waitFor { devin.turnCount >= 1 }
        XCTAssertTrue(ran)
        messages = try await service.readMessages(receipt.taskID)
        XCTAssertFalse(messages.contains {
            $0.body.contains("Lease for") && $0.seq > 0 })
        await service.shutdown()
    }

    func testRestartRestoresUnstartedChangeRequestedWriterWakeupOnce() async throws {
        let root = "/private/tmp/revision-recovery-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let db = try Database(path: root + "/test.sqlite")
        let service = try CollaborationService(database: db, adapters: [],
            dispatcherEnabled: false, wakeupCoalescence: .seconds(30))
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "Revision", objective: "Test",
            phase: .execution, participants: [.devin]))
        let repo = WorkshopRepository(db: db)
        let now = Date()
        try repo.insertSubtask(Subtask(id: SubtaskID("sub_revision"),
            taskID: receipt.taskID, title: "Revise", ownerID: .devin,
            generation: 1, state: .working, verification: "changes_requested",
            createdAt: now, updatedAt: now))
        try repo.updateTaskState(receipt.taskID, .working, at: now)

        await service.start()
        await service.start()
        let wakeups = try await service.wakeupsForTest(receipt.taskID)
        XCTAssertEqual(wakeups.filter { $0.reason == "changes_requested" }.count, 1)
        XCTAssertEqual(wakeups.first?.state, "pending")
        await service.shutdown()
    }
}
