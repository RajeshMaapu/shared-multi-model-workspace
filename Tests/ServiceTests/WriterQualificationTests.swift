import XCTest
@testable import WorkshopCore
@testable import WorkshopService

final class WriterQualificationTests: XCTestCase {
    private struct Unqualified: EngineerAdapter {
        let fake: FakeAdapter
        var engineer: EngineerID { fake.engineer }
        func probe() async -> AdapterProbe { await fake.probe() }
        func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
            try await fake.openTaskSession(binding: binding)
        }
        func sendTurn(ref: SessionRef, turnID: String, context: TurnContext, deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
            fake.sendTurn(ref: ref, turnID: turnID, context: context, deadline: deadline)
        }
        func cancelTurn(ref: SessionRef, turnID: String) async -> Bool {
            await fake.cancelTurn(ref: ref, turnID: turnID)
        }
    }

    func testV2BlocksUnqualifiedAdapterAndPreservesLegacyRouting() async throws {
        let root = NSTemporaryDirectory() + "writer-qualification-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for version in [1, 2] {
            let fake = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
            let service = try CollaborationService(databasePath: root + "/v\(version).sqlite", adapters: [Unqualified(fake: fake)])
            let receipt = try await service.createTask(CreateTaskRequest(
                schemaVersion: version, idempotencyKey: "test-\(version)", title: "Qualification", objective: "Test",
                phase: .execution, participants: [.devin]))
            await service.start()
            await service.awaitIdle()
            let detail = try await service.getTask(receipt.taskID)
            if version == 2 {
                XCTAssertEqual(fake.turnCount, 0)
                XCTAssertEqual(detail.task.state, .blocked)
                let messages = try await service.readMessages(receipt.taskID)
                XCTAssertTrue(messages.contains { $0.body == "Native workspace writer isolation is not qualified for this adapter; no turn was started" })
                do {
                    try await service.reassignSubtask(subtaskID: detail.subtasks[0].id, newOwner: .kimi, principal: .user)
                    XCTFail("Unqualified transfer must fail")
                } catch WorkshopError.invalidRequest {}
            } else {
                XCTAssertEqual(fake.turnCount, 1)
            }
            await service.shutdown()
        }
    }
}
