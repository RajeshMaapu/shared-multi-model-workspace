import XCTest
@testable import WorkshopCore
@testable import WorkshopService
@testable import WorkshopStore

final class RevisionRecoveryTests: XCTestCase {
    private struct StartupFailureAdapter: EngineerAdapter {
        let engineer: EngineerID = .devin
        let supportsIsolatedWorkspaceTurns = true
        func probe() async -> AdapterProbe { await FakeAdapter(engineer: .devin).probe() }
        func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
            throw WorkshopError.invalidRequest("startup unavailable")
        }
        func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                      deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func cancelTurn(ref: SessionRef, turnID: String) async -> Bool { true }
    }

    func testFailedStartupBlocksImmediatelyWithoutLeaseExpiryOrReassignment() async throws {
        let root = "/private/tmp/startup-recovery-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let db = try Database(path: root + "/test.sqlite")
        let service = try CollaborationService(database: db,
            adapters: [StartupFailureAdapter()], dispatcherEnabled: false)
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "Startup", objective: "Test",
            phase: .execution, participants: [.devin]))
        let before = try await service.getTask(receipt.taskID)
        _ = try await service.claimForTest(subtaskID: before.subtasks[0].id,
            owner: .devin, expectedGeneration: before.subtasks[0].generation)
        await service.runTurnForTest(engineer: .devin, taskID: receipt.taskID)
        let after = try await service.getTask(receipt.taskID)
        XCTAssertEqual(after.subtasks[0].state, .blocked)
        XCTAssertEqual(after.subtasks[0].ownerID, .devin)
        XCTAssertEqual(after.subtasks[0].generation, before.subtasks[0].generation + 1)
        await service.sweepExpiredLeases()
        let messages = try await service.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains { $0.body.contains("startup failed before execution") })
        XCTAssertFalse(messages.contains { $0.body.contains("Lease for") })
        let wakeups = try await service.wakeupsForTest(receipt.taskID)
        XCTAssertTrue(wakeups.isEmpty)
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
