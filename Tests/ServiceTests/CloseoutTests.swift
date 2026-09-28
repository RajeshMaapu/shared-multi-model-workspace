import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-D6 (packet byte bound + inline image stripping) and G-C5 (peer review
/// seeding from the owner's digest-verified sealed snapshot).
final class CloseoutTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-co-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(adapters: [FakeAdapter], schemaV2: Bool = false)
        throws -> (CollaborationService, String) {
        let dbPath = dir + "/db-\(UUID().uuidString).sqlite"
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
        return (svc, dbPath)
    }

    private func task(_ svc: CollaborationService, participants: [EngineerID],
                      schemaVersion: Int = 1) async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            schemaVersion: schemaVersion,
            idempotencyKey: UUID().uuidString, title: "T", objective: "obj",
            phase: .execution, participants: participants,
            collaborationMode: schemaVersion == 2
                ? (participants.count > 1 ? .requestedPeers : .ownerOnly)
                : nil))
        return receipt.taskID
    }

    // MARK: - G-D6 packet byte bound

    /// 60 committed messages of 1 KiB each exceed the 24 KiB body budget:
    /// the packet keeps the newest slice and names the omitted count.
    func testPacketByteBoundDropsOldest() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let (svc, _) = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin])
        await svc.start()
        let chunk = String(repeating: "x", count: 1024)
        for i in 0..<60 {
            _ = try await svc.postMessage(taskID: taskID,
                                          body: "\(i)-" + chunk,
                                          principal: .user)
        }
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                                 wakeReason: "user_message")
        let ctx = try XCTUnwrap(devin.receivedContexts.last)
        XCTAssertLessThanOrEqual(ctx.recentMessages.count, 24)
        // The newest message is always kept.
        XCTAssertTrue(ctx.recentMessages.last?.body.hasPrefix("59-") ?? false)
        let note = try XCTUnwrap(ctx.truncatedNote)
        XCTAssertTrue(note.contains("older messages omitted for size"), note)
        let packet = ctx.packetText(for: .devin)
        XCTAssertTrue(packet.contains("omitted for size"), packet)
        await svc.shutdown()
    }

    /// Inline base64 image blobs never reach the rendered packet.
    func testPacketStripsInlineImages() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let (svc, _) = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin])
        await svc.start()
        _ = try await svc.postMessage(
            taskID: taskID,
            body: "look: data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA== done",
            principal: .user)
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                                 wakeReason: "user_message")
        let packet = devin.receivedContexts.last!.packetText(for: .devin)
        XCTAssertTrue(packet.contains("[image omitted]"), packet)
        XCTAssertFalse(packet.contains("iVBORw0KGgo"), packet)
        XCTAssertFalse(packet.contains("base64,"), packet)
        await svc.shutdown()
    }

    // MARK: - G-C5 peer seeding rule

    /// A peer discussion turn is seeded from the owner's digest-verified
    /// sealed snapshot: the fenced workspace carries proposal.txt verbatim,
    /// and the generation row is `discussion`. A second owner writer turn is
    /// seeded from that same sealed snapshot.
    func testPeerSeededFromOwnerSealedSnapshot() async throws {
        let adapters = fakes()
        let devin = adapters.first { $0.engineer == .devin }!
        let kimi = adapters.first { $0.engineer == .kimi }!
        let (svc, dbPath) = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin, .kimi],
                                    schemaVersion: 2)
        await svc.start()
        let sub = try await svc.getTask(taskID).subtasks[0]
        _ = try await svc.claimForTest(subtaskID: sub.id, owner: .devin,
                                       expectedGeneration: sub.generation)
        // Owner writer turn: writes proposal.txt into the fenced workspace,
        // then reports a result; the generation seals at commit.
        devin.script = { context in
            if let path = context.workspace?.path {
                try? "proposal-v1".write(
                    toFile: path + "/proposal.txt", atomically: true,
                    encoding: .utf8)
            }
            guard let sub = context.subtask else { return [.text("none")] }
            return [.text("sealed proposal ready"),
                    .toolCall("workshop_report_result", .object([
                        "task_id": .string(context.task.id.rawValue),
                        "subtask_id": .string(sub.id.rawValue),
                        "summary": .string("r1"),
                        "generation": .number(Double(sub.generation))]))]
        }
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                                 wakeReason: "assigned")
        let devinGen = try await svc.writerGenerationStateForTest(
            taskID: taskID, engineer: .devin)
        XCTAssertEqual(devinGen, "sealed")

        // Peer discussion turn: fresh fenced copy, state 'discussion'.
        kimi.script = { _ in [.text("peer look")] }
        await svc.runTurnForTest(engineer: .kimi, taskID: taskID,
                                 wakeReason: "mention:msg_seed")
        let kimiCtx = try XCTUnwrap(kimi.receivedContexts.last)
        XCTAssertEqual(kimiCtx.workspace?.state, "discussion")
        let kimiPath = try XCTUnwrap(kimiCtx.workspace?.path)
        XCTAssertTrue(kimiPath.contains("/writer-runs/"), kimiPath)
        XCTAssertEqual(try String(contentsOfFile: kimiPath + "/proposal.txt"),
                       "proposal-v1")
        // The row is 'discussion' while the turn runs and seals to
        // 'review_only' at commit — fenced, never promotable.
        let kimiGen = try await svc.writerGenerationStateForTest(
            taskID: taskID, engineer: .kimi)
        XCTAssertEqual(kimiGen, "review_only")

        // A second owner writer turn is seeded from the sealed snapshot too.
        devin.script = { _ in [.text("owner revises")] }
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                                 wakeReason: "changes_requested")
        let devinPath = try XCTUnwrap(devin.receivedContexts.last?.workspace?.path)
        XCTAssertEqual(try String(contentsOfFile: devinPath + "/proposal.txt"),
                       "proposal-v1")
        let devinGen2 = try await svc.writerGenerationStateForTest(
            taskID: taskID, engineer: .devin)
        XCTAssertEqual(devinGen2, "sealed")
        await svc.shutdown()
        _ = dbPath
    }
}
