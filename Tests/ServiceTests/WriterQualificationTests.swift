import XCTest
@testable import WorkshopCore
@testable import WorkshopService
@testable import WorkshopStore

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

    private func makeHome() -> String {
        let root = NSTemporaryDirectory() + "writer-qualification-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForTurns(_ adapter: FakeAdapter, _ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if adapter.turnCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return adapter.turnCount >= count
    }

    private func waitForWakeReason(_ adapter: FakeAdapter,
                                   _ reason: String) async -> TurnContext? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ctx = adapter.receivedContexts.first(where: {
                $0.wakeReason == reason }) { return ctx }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
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
                XCTAssertTrue(messages.contains {
                    $0.body.hasPrefix("Native workspace writer isolation is not qualified for this adapter") })
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

    /// Discussion wakeups are read-only turns: unqualified adapters run them on
    /// a fenced non-authoritative generation instead of being blocked outright.
    func testV2DiscussionWakeupRunsUnqualifiedPeer() async throws {
        let root = makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        let ds = FakeAdapter(engineer: .deepseek, delayPerDelta: .zero)
        let devin = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        let service = try CollaborationService(
            databasePath: root + "/db.sqlite",
            adapters: [Unqualified(fake: devin), Unqualified(fake: kimi),
                       Unqualified(fake: ds)],
            dispatcherEnabled: true, homeDir: root, wakeupCoalescence: .zero)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "disc", title: "T", objective: "obj",
            phase: .researchProposal, participants: [.devin, .kimi, .deepseek],
            collaborationMode: .requestedPeers))
        await service.start()
        let kimiRan = await waitForTurns(kimi, 1)
        let dsRan = await waitForTurns(ds, 1)
        let devinRan = await waitForTurns(devin, 1)
        await service.awaitIdle()
        XCTAssertTrue(kimiRan)
        XCTAssertTrue(dsRan)
        XCTAssertTrue(devinRan)

        // Turns ran, replies committed, and no isolation gate fired.
        let detail = try await service.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .researching)
        let messages = try await service.readMessages(receipt.taskID)
        XCTAssertFalse(messages.contains { $0.body.contains("not qualified") })
        XCTAssertTrue(messages.contains { $0.author == .engineer(.kimi) && $0.deliveryState == .committed })
        XCTAssertTrue(messages.contains { $0.author == .engineer(.deepseek) && $0.deliveryState == .committed })

        // The discussion workspace was a fenced read-only copy: the packet told
        // the model so, and the generation sealed to review_only (never
        // promotable — promote() requires the 'sealed' state).
        let kimiContext = try XCTUnwrap(kimi.receivedContexts.first)
        XCTAssertEqual(kimiContext.workspace?.state, "discussion")
        XCTAssertTrue(kimiContext.packetText(for: .kimi).contains("never promoted"))
        let db = try Database(path: root + "/db.sqlite")
        let states = try db.query("SELECT DISTINCT state FROM writer_generations")
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.allSatisfy { $0["state"]?.text == "review_only" })
        await service.shutdown()
    }

    /// An unqualified adapter still cannot run an authoritative execution turn:
    /// claiming a subtask and dispatching the owner blocks with the gate event.
    func testV2ExecutionTurnStillGatedForUnqualifiedOwner() async throws {
        let root = makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        let service = try CollaborationService(
            databasePath: root + "/db.sqlite",
            adapters: [Unqualified(fake: kimi)],
            dispatcherEnabled: false, homeDir: root, wakeupCoalescence: .zero)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "exec", title: "T", objective: "obj",
            phase: .execution, participants: [.kimi],
            collaborationMode: .requestedPeers))
        await service.start()
        let detail = try await service.getTask(receipt.taskID)
        let sub = try XCTUnwrap(detail.subtasks.first)
        let claimed = try await service.claimForTest(
            subtaskID: sub.id, owner: .kimi, expectedGeneration: 0)
        XCTAssertTrue(claimed)
        await service.runTurnForTest(engineer: .kimi, taskID: receipt.taskID)
        await service.awaitIdle()
        let after = try await service.getTask(receipt.taskID)
        XCTAssertEqual(after.task.state, .blocked)
        let messages = try await service.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains {
            $0.body.hasPrefix("Native workspace writer isolation is not qualified for this adapter") })
        // The refused turn created no authoritative generation: any rows are
        // the fenced review_only output of legitimate discussion turns.
        let db = try Database(path: root + "/db.sqlite")
        let rows = try db.query("""
            SELECT id FROM writer_generations
            WHERE task_id=? AND state IN ('writing','sealed','accepted')
            """, [.text(receipt.taskID.rawValue)])
        XCTAssertTrue(rows.isEmpty)
        await service.shutdown()
    }

    /// An owner replying to a user message is still a discussion turn: the
    /// workspace stays read-only even though the peer owns a subtask.
    func testV2UserReplyToOwnerRunsAsDiscussion() async throws {
        let root = makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        let service = try CollaborationService(
            databasePath: root + "/db.sqlite",
            adapters: [Unqualified(fake: kimi)],
            dispatcherEnabled: false, homeDir: root, wakeupCoalescence: .zero)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "mention", title: "T", objective: "obj",
            phase: .execution, participants: [.kimi],
            collaborationMode: .requestedPeers))
        await service.start()
        let detail = try await service.getTask(receipt.taskID)
        let sub = try XCTUnwrap(detail.subtasks.first)
        let claimed = try await service.claimForTest(
            subtaskID: sub.id, owner: .kimi, expectedGeneration: 0)
        XCTAssertTrue(claimed)
        _ = try await service.postMessage(taskID: receipt.taskID, body: "ping")
        let ctx = await waitForWakeReason(kimi, "user_message")
        await service.awaitIdle()
        XCTAssertEqual(ctx?.workspace?.state, "discussion")
        XCTAssertTrue(kimi.receivedContexts.allSatisfy {
            $0.workspace?.state == "discussion" })
        let db = try Database(path: root + "/db.sqlite")
        let states = try db.query("SELECT DISTINCT state FROM writer_generations")
        XCTAssertTrue(states.allSatisfy { $0["state"]?.text == "review_only" })
        await service.shutdown()
    }

    /// A user @mention wakes the named peer even when no subtask is owned —
    /// the compose UI advertises "@mention an engineer"; previously a user
    /// mention was silently ignored because only engineer authors were scanned.
    func testV2UserMentionWakesPeerWithoutOwnedSubtask() async throws {
        let root = makeHome()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        let devin = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        let service = try CollaborationService(
            databasePath: root + "/db.sqlite",
            adapters: [Unqualified(fake: kimi), Unqualified(fake: devin)],
            dispatcherEnabled: false, homeDir: root, wakeupCoalescence: .zero)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "user-mention", title: "T", objective: "obj",
            phase: .execution, participants: [.kimi, .devin],
            collaborationMode: .requestedPeers))
        await service.start()
        // Build engineer-triggered mention history at/past the loop bound, as a
        // real discussion would; each engineer @kimi produces one wakeup.
        for i in 0..<7 {
            _ = try await service.postMessage(taskID: receipt.taskID,
                                              body: "@kimi ping \(i)",
                                              principal: .engineer(.devin))
            _ = await waitForTurns(kimi, i + 1)
        }
        let preUser = await waitForWakeReason(kimi, "mention")
        XCTAssertNotNil(preUser)
        let userMessage = try await service.postMessage(taskID: receipt.taskID,
                                          body: "@kimi please review the proposal")
        // The fresh user message resets the loop bound: the mention must not
        // be suppressed even though engineer wakeups alone already hit it.
        let db = try Database(path: root + "/db.sqlite")
        let pending = try db.query("""
            SELECT state FROM wakeups
            WHERE engineer_id='kimi' AND reason='mention' AND trigger_seq=?
            """, [.integer(Int64(userMessage.seq))])
        XCTAssertNotEqual(pending.first?["state"]?.text, "suppressed")
        XCTAssertNotNil(pending.first)
        let kimiBefore = kimi.turnCount
        _ = await waitForTurns(kimi, kimiBefore + 1)
        await service.awaitIdle()
        XCTAssertTrue(kimi.receivedContexts.contains { $0.wakeReason == "mention" })
        await service.shutdown()
    }
}
