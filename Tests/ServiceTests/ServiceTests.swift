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
        // The owner's report_requested nudge may add a follow-up turn.
        XCTAssertGreaterThanOrEqual(adapters[0].turnCount, 1)
    }

    func testExplicitCollaborationKeepsExistingPeersAndCleanInstructions() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(request(
            objective: "Collaborate with Kimi and DeepSeek on a joint architecture audit",
            phase: .researchProposal))
        await svc.start()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && adapters.contains(where: { $0.turnCount == 0 }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        for adapter in adapters {
            XCTAssertEqual(adapter.turnCount, 1)
            let packet = try XCTUnwrap(adapter.receivedContexts.first).packetText(for: adapter.engineer)
            XCTAssertTrue(packet.contains("engage the existing requested peers"))
            XCTAssertTrue(packet.contains("Incorporate their responses"))
            XCTAssertTrue(packet.contains("do not spawn additional agents"))
        }
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.participants.count, 3)
        await svc.shutdown()
    }

    func testLegacySessionIsPreservedAndNeverDispatched() async throws {
        let setup = try service(adapters: fakes(), dispatcher: false, file: "legacy.sqlite")
        let receipt = try await setup.createTask(request())
        await setup.shutdown()
        let repo = WorkshopRepository(db: try Database(path: dir + "/legacy.sqlite"))
        try repo.saveSessionBinding(.init(taskID: receipt.taskID, engineerID: .devin,
            role: "owner", workerID: "main", nativeSessionID: "personal-history-canary",
            profileRevision: 1))
        let adapters = fakes()
        let resumed = try service(adapters: adapters, file: "legacy.sqlite")
        await resumed.start(); await resumed.awaitIdle()
        XCTAssertEqual(adapters.map(\.turnCount).reduce(0, +), 0)
        let stored = try repo.sessionBinding(taskID: receipt.taskID, engineerID: .devin,
                                             role: "owner", workerID: "main")
        XCTAssertEqual(stored?.nativeSessionID, "personal-history-canary")
        let messages = try await resumed.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains { $0.body.contains("old history was not resumed") })
        await resumed.shutdown()
    }

    /// After two consecutive native session/load timeouts Kimi skips the
    /// bounded load and opens fresh, with the note posted exactly once.
    func testKimiSessionReloadSkippedAfterTwoTimeouts() async throws {
        let adapters = fakes()
        let kimi = try XCTUnwrap(adapters.first { $0.engineer == .kimi })
        let svc = try service(adapters: adapters, dispatcher: false)
        let receipt = try await svc.createTask(request())
        let taskID = receipt.taskID
        try svc.repoForTests.db.execute("""
            INSERT INTO session_bindings(task_id,engineer_id,role,worker_id,
                native_session_id,profile_revision,model_selection,
                recovery_state,load_timeout_count)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(taskID.rawValue), .text("kimi"), .text("owner"),
                  .text("main"), .text("session-stale"), .integer(2),
                  .text("k3"), .text("bound"), .integer(2)])
        await svc.runTurnForTest(engineer: .kimi, taskID: taskID,
                                 wakeReason: "mention")
        XCTAssertNil(kimi.receivedBindings.last?.nativeSessionID)
        var notes = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent
                && $0.body.contains("Kimi native session reload skipped")
        }
        XCTAssertEqual(notes.count, 1)
        // The skip stays armed and the note is not repeated.
        await svc.runTurnForTest(engineer: .kimi, taskID: taskID,
                                 wakeReason: "mention")
        XCTAssertNil(kimi.receivedBindings.last?.nativeSessionID)
        notes = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent
                && $0.body.contains("Kimi native session reload skipped")
        }
        XCTAssertEqual(notes.count, 1)
        await svc.shutdown()
    }

    /// A load-timeout note bumps the binding's counter; a successful load
    /// (returned session equals the stored one) resets it.
    func testKimiLoadTimeoutCountedAndResetOnSuccess() async throws {
        let adapters = fakes()
        let kimi = try XCTUnwrap(adapters.first { $0.engineer == .kimi })
        let svc = try service(adapters: adapters, dispatcher: false)
        let receipt = try await svc.createTask(request())
        let taskID = receipt.taskID
        let bindingRow = "SELECT load_timeout_count FROM session_bindings "
            + "WHERE task_id=? AND engineer_id='kimi'"
        func count() throws -> Int64? {
            try svc.repoForTests.db.query(bindingRow,
                                          [.text(taskID.rawValue)])
                .first?["load_timeout_count"]?.int
        }
        try svc.repoForTests.db.execute("""
            INSERT INTO session_bindings(task_id,engineer_id,role,worker_id,
                native_session_id,profile_revision,model_selection,
                recovery_state,load_timeout_count)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(taskID.rawValue), .text("kimi"), .text("owner"),
                  .text("main"), .text("session-a"), .integer(2),
                  .text("k3"), .text("bound"), .integer(0)])
        kimi.script = { _ in
            [.event(.uncertain(
                "Native session for kimi could not be loaded "
                + "(ACP session/load timed out); started a new session "
                + "(no checkpoint available yet)"))]
        }
        await svc.runTurnForTest(engineer: .kimi, taskID: taskID,
                                 wakeReason: "mention")
        XCTAssertEqual(try count(), 1)

        // A successful session/load (adapter returns the stored id) resets.
        kimi.script = nil
        try svc.repoForTests.db.execute("""
            UPDATE session_bindings SET native_session_id=?,
                load_timeout_count=1
            WHERE task_id=? AND engineer_id='kimi'
            """, [.text("fake-session-" + taskID.rawValue),
                  .text(taskID.rawValue)])
        await svc.runTurnForTest(engineer: .kimi, taskID: taskID,
                                 wakeReason: "mention")
        XCTAssertEqual(try count(), 0)
        await svc.shutdown()
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
        // The owner's report_requested nudge may add a follow-up turn;
        // peers still run none.
        XCTAssertEqual(counts[1] + counts[2], 0)
        XCTAssertGreaterThanOrEqual(adapters[0].turnCount, 1) // devin first in order
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
        // The owner's report_requested nudge may add a follow-up turn.
        XCTAssertGreaterThanOrEqual(adapters[0].turnCount, 1)
        XCTAssertEqual(adapters[1].turnCount + adapters[2].turnCount, 0)
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
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        // A state_changed row is only emitted when the task actually
        // transitions — script the owner turn to report a result.
        adapters[0].toolRunner = { [weak svc] name, args, principal in
            guard let svc else { return .null }
            return try await svc.callTool(name, args: args, principal: principal)
        }
        adapters[0].script = { context in
            guard let sub = context.subtask else { return [.text("ok")] }
            return [.toolCall("workshop_report_result", .object([
                "task_id": .string(context.task.id.rawValue),
                "subtask_id": .string(sub.id.rawValue),
                "summary": .string("done"),
                "generation": .number(Double(sub.generation))]))]
        }
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
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        for adapter in adapters {
            adapter.toolRunner = { [weak svc] name, args, principal in
                guard let svc else { return .null }
                return try await svc.callTool(name, args: args, principal: principal)
            }
            adapter.script = { context in
                guard let sub = context.subtask,
                      sub.ownerID == adapter.engineer else { return [.text("ok")] }
                return [.toolCall("workshop_report_result", .object([
                    "task_id": .string(context.task.id.rawValue),
                    "subtask_id": .string(sub.id.rawValue),
                    "summary": .string("done"),
                    "generation": .number(Double(sub.generation))]))]
            }
        }
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
