import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-D3 (task-memory packets), G-C4 (owner writer-turn coalescing) and
/// G-D2 (startup-failure classification).
final class TaskMemoryTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-tm-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(adapters: [FakeAdapter], dispatcher: Bool = false)
        throws -> CollaborationService {
        let svc = try CollaborationService(
            databasePath: dir + "/db-\(UUID().uuidString).sqlite",
            adapters: adapters, dispatcherEnabled: dispatcher, homeDir: dir,
            wakeupCoalescence: .zero,
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

    private func task(_ svc: CollaborationService, participants: [EngineerID],
                      schemaVersion: Int = 1) async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            schemaVersion: schemaVersion,
            idempotencyKey: UUID().uuidString, title: "T", objective: "obj",
            phase: .execution, participants: participants))
        return receipt.taskID
    }

    private func waitFor(_ predicate: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await predicate()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Scripted owner turn: one text reply + a workshop_report_result call.
    private func reportingScript(_ context: TurnContext)
        async -> [FakeAdapter.ScriptedAction] {
        guard let sub = context.subtask else { return [.text("no subtask")] }
        return [.toolCall("workshop_post_message", .object([
                    "task_id": .string(context.task.id.rawValue),
                    "body": .string("worked on it")])),
                .text("streamed recap"),
                .toolCall("workshop_report_result", .object([
                    "task_id": .string(context.task.id.rawValue),
                    "subtask_id": .string(sub.id.rawValue),
                    "summary": .string("round done"),
                    "generation": .number(Double(sub.generation))]))]
    }

    // MARK: (a) memory ring

    func testTurnRecordRingKeepsNewestEight() async throws {
        let adapters = fakes()
        let svc = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        let sub = try await svc.getTask(taskID).subtasks[0]
        _ = try await svc.claimForTest(subtaskID: sub.id, owner: .devin,
                                       expectedGeneration: sub.generation)
        for _ in 0..<10 {
            await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        }
        let records = try await svc.taskMemoryForTest(taskID: taskID,
                                                      engineer: .devin)
        XCTAssertEqual(records.count, 8)
        XCTAssertTrue(records.allSatisfy { $0.outcome == "completed" })
        XCTAssertTrue(records.allSatisfy { !$0.postedSeqs.isEmpty })
        // Oldest two turns were evicted; order is oldest → newest.
        let seqs = records.map { $0.postedSeqs.last ?? 0 }
        XCTAssertEqual(seqs, seqs.sorted())

        // A scripted turn that reports a result records its revision.
        let devin = adapters.first { $0.engineer == .devin }!
        devin.script = reportingScript
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        let after = try await svc.taskMemoryForTest(taskID: taskID,
                                                    engineer: .devin)
        XCTAssertEqual(after.count, 8)
        XCTAssertEqual(after.last?.resultRevision, 1)
        await svc.shutdown()
    }

    // MARK: (b) packet memory section + session freshness

    func testPacketCarriesMemorySection() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        devin.script = reportingScript
        let svc = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        let sub = try await svc.getTask(taskID).subtasks[0]
        _ = try await svc.claimForTest(subtaskID: sub.id, owner: .devin,
                                       expectedGeneration: sub.generation)
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)

        devin.script = { _ in [.text("second turn")] }
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        let packet = devin.receivedContexts.last!.packetText(for: .devin)
        XCTAssertTrue(packet.contains("## Your memory for this task"))
        XCTAssertTrue(packet.contains("Your recent turns:"))
        XCTAssertTrue(packet.contains("posted seq"))
        XCTAssertTrue(packet.contains("result revision 1"))
        XCTAssertTrue(packet.contains("Native session: resumed"))
        XCTAssertTrue(packet.contains("worked on it"))

        // A fresh native session is labelled so the engineer relies on memory.
        devin.reportsFreshSession = true
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        let fresh = devin.receivedContexts.last!.packetText(for: .devin)
        XCTAssertTrue(fresh.contains("Native session: fresh"))
        await svc.shutdown()
    }

    // MARK: (c) peer dispositions on the latest result

    func testPeerDispositionsInPacket() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        devin.script = reportingScript
        let svc = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        let sub = try await svc.getTask(taskID).subtasks[0]
        _ = try await svc.claimForTest(subtaskID: sub.id, owner: .devin,
                                       expectedGeneration: sub.generation)
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        let result = try await svc.readMessages(taskID).first {
            $0.structured?.contains("\"type\":\"result\"") == true
                || $0.structured?.contains("\"type\": \"result\"") == true
        }
        XCTAssertNotNil(result)
        _ = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(result!.id.rawValue),
            "severity": .string("medium"),
            "disposition": .string("needs_changes"),
            "body": .string("needs more evidence")]),
            principal: .engineer(.kimi))

        devin.script = { _ in [.text("next turn")] }
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        let packet = devin.receivedContexts.last!.packetText(for: .devin)
        XCTAssertTrue(packet.contains("kimi=needs_changes"), packet)
        await svc.shutdown()
    }

    // MARK: (d) memory section is bounded

    func testMemorySectionBounded() throws {
        let long = String(repeating: "x", count: 4000)
        let records = (0..<8).map { i in
            TurnRecord(turnID: "t\(i)", endedAt: Date(), reason: "mention",
                       outcome: "completed",
                       postedSeqs: [Int64(i), Int64(i + 100)],
                       filesTouched: (0..<20).map { "dir/file-\(i)-\($0).swift" })
        }
        let messages = (0..<3).map { i in
            Message(id: MessageID("m\(i)"), taskID: TaskID("task_x"), seq: Int64(i),
                    author: .engineer(.devin), kind: .text, body: long,
                    deliveryState: .committed, createdAt: Date(), updatedAt: Date())
        }
        let packet = TaskMemoryPacket(turnRecords: records,
                                      latestCheckpoint: .object([
                                          "objective": .string(long)]),
                                      ownRecentMessages: messages,
                                      latestResult: ("m0", 3, "sub_1"),
                                      peerDispositions: [(.kimi, "needs_changes", 55)],
                                      sessionResumed: false)
        let section = packet.renderedSection().joined(separator: "\n")
        XCTAssertLessThanOrEqual(section.utf8.count, 6144)
        XCTAssertTrue(section.contains("## Your memory for this task"))
        XCTAssertTrue(section.contains("Native session: fresh"))
    }

    // MARK: (e) owner writer-turn coalescing

    func testOwnerMentionCoalescesIntoWriterTurn() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let svc = try makeService(adapters: adapters, dispatcher: true)
        let taskID = try await task(svc, participants: [.devin],
                                    schemaVersion: 2)
        await svc.start()
        // Initial owner dispatch: subtask claimed → working; the unscripted
        // turn ends without a result and the report nudge runs one more turn.
        let settled = await waitFor {
            let d = try await svc.getTask(taskID)
            return d.subtasks[0].state == .working && devin.turnCount >= 2
        }
        XCTAssertTrue(settled)
        let beforeTurns = devin.turnCount

        _ = try await svc.postMessage(taskID: taskID,
                                      body: "@devin please also handle X",
                                      principal: .user)
        let woke = await waitFor { devin.turnCount > beforeTurns }
        XCTAssertTrue(woke)
        let ctx = devin.receivedContexts.last!
        XCTAssertEqual(ctx.wakeReason, "user_mention")
        XCTAssertEqual(ctx.workspace?.state, "writer")
        XCTAssertEqual(ctx.capabilities, .writer)
        let packet = ctx.packetText(for: .devin)
        XCTAssertTrue(packet.contains("The user mentioned you directly"), packet)
        XCTAssertTrue(packet.contains("authoritative writer turn"), packet)
        await svc.shutdown()
    }

    /// Once the subtask is in review there is nothing to edit: mentions run
    /// as discussion turns.
    func testOwnerMentionDuringReviewStaysDiscussion() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        devin.script = reportingScript
        let svc = try makeService(adapters: adapters, dispatcher: true)
        let taskID = try await task(svc, participants: [.devin],
                                    schemaVersion: 2)
        await svc.start()
        let settled = await waitFor {
            let d = try await svc.getTask(taskID)
            return d.subtasks[0].state == .review && devin.turnCount >= 1
        }
        XCTAssertTrue(settled)
        devin.script = { _ in [.text("ack")] }
        let beforeTurns = devin.turnCount
        _ = try await svc.postMessage(taskID: taskID,
                                      body: "@devin thoughts?",
                                      principal: .user)
        let woke = await waitFor { devin.turnCount > beforeTurns }
        XCTAssertTrue(woke)
        let ctx = devin.receivedContexts.last!
        XCTAssertEqual(ctx.wakeReason, "user_mention")
        XCTAssertEqual(ctx.workspace?.state, "discussion")
        XCTAssertFalse(ctx.packetText(for: .devin)
            .contains("authoritative writer turn"))
        await svc.shutdown()
    }

    /// A verify_result wake to the owner never becomes authoritative.
    func testVerifyResultNeverAuthoritative() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let svc = try makeService(adapters: adapters, dispatcher: true)
        let taskID = try await task(svc, participants: [.devin],
                                    schemaVersion: 2)
        await svc.start()
        let settled = await waitFor {
            try await svc.getTask(taskID).subtasks[0].state == .working
        }
        XCTAssertTrue(settled)
        let beforeTurns = devin.turnCount
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                                 wakeReason: "verify_result:msg_x")
        XCTAssertGreaterThan(devin.turnCount, beforeTurns)
        let ctx = devin.receivedContexts.last!
        XCTAssertEqual(ctx.wakeReason, "verify_result:msg_x")
        XCTAssertEqual(ctx.workspace?.state, "discussion")
        XCTAssertFalse(ctx.authoritativeOwnerTurn)
        await svc.shutdown()
    }

    // MARK: (f) startup-failure classification

    func testStartupFailureClassification() {
        XCTAssertEqual(StartupFailureClass.classify(
            "ACP remote error -32000: Authentication required"), .auth)
        XCTAssertEqual(StartupFailureClass.classify(
            "OAuthUnauthorized: authorization grant needed"), .auth)
        XCTAssertEqual(StartupFailureClass.classify(
            "kimi session/new failed: ACP session/new timed out"), .timeout)
        XCTAssertEqual(StartupFailureClass.classify(
            "fusion-relay: timed out"), .timeout)
        XCTAssertEqual(StartupFailureClass.classify(
            "Can not write to FileHandle after it's closed."), .transport)
        XCTAssertEqual(StartupFailureClass.classify(
            "EPERM: operation not permitted"), .sandbox)
        XCTAssertEqual(StartupFailureClass.classify(
            "ACP remote error -32603: Internal error"), .internal)
        XCTAssertEqual(StartupFailureClass.classify(
            "no such executable"), .unknown)
    }

    // MARK: (g) auth failures stop after one retry and surface a remedy

    func testAuthFailureCapsRetriesAndSurfacesRemedy() async throws {
        let adapters = fakes()
        let kimi = adapters.first { $0.engineer == .kimi }!
        kimi.openSessionError = WorkshopError.invalidRequest(
            "ACP remote error -32000: Authentication required")
        let svc = try makeService(adapters: adapters, dispatcher: true)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi hi",
                                      principal: .engineer(.devin))
        let failed = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.state == "launch_failed" }
        }
        XCTAssertTrue(failed)
        // One deferred retry, then launch_failed (auth is not retried 3×).
        XCTAssertEqual(kimi.openAttempts, 2)
        let events = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent
        }
        XCTAssertTrue(events.contains {
            $0.body.contains("Login required for Kimi K3")
                && $0.body.contains("kimi acp --login") })
        let probes = await svc.listEngineers()
        let kimiProbe = probes.first { $0.engineer == .kimi }!
        XCTAssertEqual(kimiProbe.health.kind, .unavailable)
        XCTAssertTrue(kimiProbe.health.detail.contains("Login required"))

        // A successful open clears the recorded failure.
        kimi.openSessionError = nil
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi back",
                                      principal: .engineer(.devin))
        let recovered = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.state == "done" }
        }
        XCTAssertTrue(recovered)
        let after = await svc.listEngineers().first { $0.engineer == .kimi }!
        XCTAssertEqual(after.health.kind, .available)
        XCTAssertFalse(after.health.detail.contains("last start failed"))
        await svc.shutdown()
    }
}
