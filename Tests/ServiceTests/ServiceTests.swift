import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

final class ServiceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-svc-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes(health: EngineerHealth = .available("ok")) -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero, health: health) }
    }

    private func service(adapters: [EngineerAdapter], dispatcher: Bool = true,
                         file: String = "db.sqlite") throws -> CollaborationService {
        try CollaborationService(databasePath: dir + "/" + file, adapters: adapters,
                                 dispatcherEnabled: dispatcher)
    }

    private func request(key: String = "k1", objective: String = "Do the thing",
                         phase: TaskPhase = .execution) -> CreateTaskRequest {
        CreateTaskRequest(idempotencyKey: key, title: "Test task", objective: objective,
                          phase: phase, participants: EngineerID.allCases)
    }

    func testT01IdempotentCreate() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let r1 = try await svc.createTask(request())
        let r2 = try await svc.createTask(request())
        XCTAssertEqual(r1, r2)
        await svc.start()
        await svc.awaitIdle()
        let tasks = try await svc.listTasks()
        XCTAssertEqual(tasks.count, 1)
        let detail = try await svc.getTask(r1.taskID)
        XCTAssertEqual(detail.participants.count, 3)
        let messages = try await svc.readMessages(r1.taskID)
        // Root message only existed once before dispatch; engineer reply + system events added.
        XCTAssertEqual(messages.filter { $0.seq == 1 }.count, 1)
        XCTAssertEqual(messages.first?.body, "Do the thing")
        XCTAssertEqual(adapters[0].turnCount, 1)
    }

    func testT02IdempotencyConflict() async throws {
        let svc = try service(adapters: fakes())
        _ = try await svc.createTask(request())
        await svc.awaitIdle()
        do {
            _ = try await svc.createTask(request(objective: "Different objective"))
            XCTFail("expected idempotencyConflict")
        } catch WorkshopError.idempotencyConflict {
        }
        let tasks = try await svc.listTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.brief, "Do the thing")
    }

    func testT04AtomicClaimSingleWinner() async throws {
        let svc = try service(adapters: fakes(), dispatcher: false)
        _ = try await svc.createTask(request())
        let task = try await svc.listTasks().first!
        let subtask = try await svc.getTask(task.id).subtasks.first!
        // Three concurrent CAS claims against one subtask.
        let results = await withTaskGroup(of: Bool.self) { group in
            for engineer in EngineerID.allCases {
                group.addTask {
                    do {
                        return try await svc.claimForTest(subtaskID: subtask.id, owner: engineer,
                                                        expectedGeneration: subtask.generation)
                    } catch {
                        print("claim error for \(engineer): \(error)")
                        return false
                    }
                }
            }
            var wins = 0
            for await ok in group where ok { wins += 1 }
            return wins
        }
        XCTAssertEqual(results, 1)
        let after = try await svc.getTask(task.id).subtasks.first!
        XCTAssertEqual(after.generation, 1)
        XCTAssertNotNil(after.ownerID)
        XCTAssertEqual(after.state, .claimed)
    }

    func testT09OneEngineerDoesWork() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(request())
        await svc.start()
        await svc.awaitIdle()
        let counts = adapters.map(\.turnCount)
        XCTAssertEqual(counts.reduce(0, +), 1)
        XCTAssertEqual(adapters[0].turnCount, 1) // devin first in order
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(Set(detail.participants.map(\.engineerID)), Set(EngineerID.allCases))
        let messages = try await svc.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains { $0.author == .engineer(.devin) && $0.deliveryState == .committed })
    }

    func testT03PreDispatchCrashRecovery() async throws {
        let path = "t03.sqlite"
        do {
            // Dispatcher disabled: commit happens, no dispatch, then the "process" goes away.
            let svc = try service(adapters: fakes(), dispatcher: false, file: path)
            _ = try await svc.createTask(request(key: "t03"))
        }
        let adapters = fakes()
        let svc2 = try service(adapters: adapters, file: path)
        await svc2.start()
        await svc2.awaitIdle()
        XCTAssertEqual(adapters.map(\.turnCount).reduce(0, +), 1)
        let pending = try await svc2.outboxEvents(afterSeq: 0)
            .filter { $0.eventType == CollaborationService.dispatchRequested }
        XCTAssertTrue(pending.allSatisfy { $0.deliveryState == "delivered" })
        XCTAssertEqual(pending.count, 1)
    }

    func testT28ReopenPreservesState() async throws {
        let path = "t28.sqlite"
        var taskID: TaskID!
        do {
            let svc = try service(adapters: fakes(), file: path)
            taskID = try await svc.createTask(request(key: "t28")).taskID
            await svc.start()
            await svc.awaitIdle()
        }
        let svc2 = try service(adapters: fakes(), file: path)
        let detail = try await svc2.getTask(taskID)
        XCTAssertEqual(detail.task.title, "Test task")
        let messages = try await svc2.readMessages(taskID)
        XCTAssertTrue(messages.contains { msg in
            if case .engineer = msg.author, msg.deliveryState == .committed,
               msg.body.contains("Test task") { return true }
            return false
        })
        let subtask = detail.subtasks.first!
        XCTAssertEqual(subtask.ownerID, .devin)
        XCTAssertEqual(subtask.generation, 1)
    }

    /// Phase 3: research tasks dispatch all participants to draft proposals.
    func testResearchProposalEntersResearching() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(request(phase: .researchProposal))
        await svc.start()
        await svc.awaitIdle()
        // Turns are wakeup-driven; wait until all participants have run.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline,
              adapters.contains(where: { $0.turnCount == 0 }) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .researching)
        for adapter in adapters {
            XCTAssertEqual(adapter.turnCount, 1,
                           "\(adapter.engineer) should get one research turn")
        }
        let messages = try await svc.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains { $0.kind == .systemEvent
            && $0.body.contains("Research phase started") })
        await svc.shutdown()
    }

    func testNoEligibleEngineerBlocksWithoutRetry() async throws {
        let down = EngineerHealth.unavailable("adapter not configured")
        let adapters = fakes(health: down)
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(request(key: "blocked"))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .blocked)
        let messages = try await svc.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains { $0.body == "No eligible engineer available" })
        // Second start(): delivered outbox row is not reprocessed.
        await svc.awaitIdle()
        await svc.processPendingDispatches()
        XCTAssertEqual(adapters.map(\.turnCount).reduce(0, +), 0)
    }

    func testInterruptedStreamMarkedUncertain() async throws {
        let path = "interrupt.sqlite"
        do {
            let svc = try service(adapters: fakes(), dispatcher: false, file: path)
            _ = try await svc.createTask(request(key: "i1"))
            // Simulate a stream left mid-flight.
            try await svc.insertStreamingMessageForTest()
        }
        let svc2 = try service(adapters: fakes(), file: path)
        await svc2.start()
        let taskID = try await svc2.listTasks().first!.id
        let messages = try await svc2.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.body.contains("[stream interrupted by service restart; marked uncertain]")
                && $0.deliveryState == .committed
        })
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent && $0.body.contains("Interrupted stream")
        })
        // The interrupted turn's subtask and task are blocked pending reconciliation.
        let detail = try await svc2.getTask(taskID)
        XCTAssertEqual(detail.task.state, .blocked)
        XCTAssertEqual(detail.subtasks.first?.state, .blocked)
    }

    func testUsageSampleKeepsUnknownCache() async throws {
        let svc = try service(adapters: fakes())
        _ = try await svc.createTask(request(key: "usage"))
        await svc.start()
        await svc.awaitIdle()
        let events = try await svc.outboxEvents(afterSeq: 0)
        let stateChanged = try XCTUnwrap(events.last { $0.eventType == "task.state_changed" })
        XCTAssertTrue(stateChanged.payload.contains(#""cache_read":null"#),
                      stateChanged.payload)
        XCTAssertTrue(stateChanged.payload.contains(#""input":812"#), stateChanged.payload)
        XCTAssertTrue(stateChanged.payload.contains(#""source":"fake""#))
    }

    func testFailedTurnDoesNotReportComplete() async throws {
        let failing = FakeAdapter(engineer: .devin, delayPerDelta: .zero,
                                  failAfterDeltas: 2)
        let adapters: [EngineerAdapter] = [failing] + EngineerID.allCases.dropFirst().map {
            FakeAdapter(engineer: $0, delayPerDelta: .zero)
        }
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(request(key: "fail-turn"))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .blocked)
        XCTAssertEqual(detail.subtasks.first?.state, .blocked)
        let messages = try await svc.readMessages(receipt.taskID)
        XCTAssertFalse(messages.contains { $0.body == "Owner reported complete; verification pending" })
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent && $0.body.hasPrefix("Turn failed:")
                && $0.body.contains("awaiting reconciliation")
        })
        XCTAssertTrue(messages.contains { $0.body.contains("[turn failed:") })
    }

    func testPoisonedDispatchRowFailsAndLoopContinues() async throws {
        let svc = try service(adapters: fakes())
        // A dispatch.requested row with no subtask_id can never be handled.
        try await svc.insertOutboxForTest(eventType: CollaborationService.dispatchRequested,
                                        taskID: nil, payload: #"{"task_id":"task_missing"}"#)
        await svc.processPendingDispatches()
        let rows = try await svc.outboxEvents(afterSeq: 0)
        let poisoned = try XCTUnwrap(rows.last { $0.eventType == CollaborationService.dispatchRequested })
        XCTAssertEqual(poisoned.deliveryState, "failed")
        XCTAssertTrue(poisoned.payload.contains("[error:"))
        // The loop exited and a real task still dispatches.
        _ = try await svc.createTask(request(key: "after-poison"))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(try await svc.listTasks().first!.id)
        XCTAssertEqual(detail.task.state, .verifying)
    }
}
