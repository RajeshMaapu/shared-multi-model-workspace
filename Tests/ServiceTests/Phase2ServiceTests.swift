import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// Phase 2a service tests: principals/auth, collaboration tools, artifacts,
/// wakeup policy (§5.4), capacity, checkpoints.
final class Phase2ServiceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-p2-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map {
            FakeAdapter(engineer: $0, delayPerDelta: .zero)
        }
    }

    private func service(participants: [EngineerID] = EngineerID.allCases,
                         loopBound: Int = 6,
                         adapters: [EngineerAdapter]? = nil)
        async throws -> (CollaborationService, TaskID) {
        let svc = try CollaborationService(
            databasePath: dir + "/db-\(UUID().uuidString).sqlite",
            adapters: adapters ?? fakes(),
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero, wakeupLoopBound: loopBound)
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "obj",
            phase: .execution, participants: participants))
        return (svc, receipt.taskID)
    }

    // MARK: - Principals

    func testEngineerCannotPostToNonParticipantTask() async throws {
        let (svc, taskID) = try await service(participants: [.devin])
        do {
            _ = try await svc.postMessage(taskID: taskID, body: "hi",
                                          principal: .engineer(.kimi))
            XCTFail("expected notAParticipant")
        } catch WorkshopError.notAParticipant(let e, let t) {
            XCTAssertEqual(e, .kimi); XCTAssertEqual(t, taskID)
        }
    }

    func testAuthorComesFromPrincipalNotParams() async throws {
        let (svc, taskID) = try await service(participants: [.kimi])
        // Params carry no author field; even a hostile "from" arg is ignored.
        let result = try await svc.callTool("workshop_post_message", args: .object([
            "task_id": .string(taskID.rawValue),
            "body": .string("hello"),
            "from": .string("user"),          // must be ignored
            "author": .string("system"),      // must be ignored
        ]), principal: .engineer(.kimi))
        let message = try result.decode(as: Message.self)
        XCTAssertEqual(message.author, .engineer(.kimi))
    }

    func testAuthenticateResolvesToken() async throws {
        let (svc, _) = try await service()
        let tokenPath = dir + "/profiles/kimi/token"
        try FileManager.default.createDirectory(
            atPath: dir + "/profiles/kimi", withIntermediateDirectories: true)
        try "cafe".write(toFile: tokenPath, atomically: true, encoding: .utf8)
        let p = try await svc.authenticate(token: "cafe")
        XCTAssertEqual(p, .engineer(.kimi))
        do {
            _ = try await svc.authenticate(token: "wrong")
            XCTFail("expected invalid token")
        } catch WorkshopError.invalidRequest {}
    }

    // MARK: - report_result ownership

    private func claimSubtask(_ svc: CollaborationService, taskID: TaskID,
                              owner: EngineerID) async throws -> SubtaskID {
        let detail = try await svc.getTask(taskID)
        let sub = detail.subtasks[0]
        let claimed = try await svc.claimForTest(subtaskID: sub.id, owner: owner,
                                                 expectedGeneration: sub.generation)
        XCTAssertTrue(claimed)
        return sub.id
    }

    func testReportResultByNonOwnerRejected() async throws {
        let (svc, taskID) = try await service(participants: [.devin, .kimi])
        let subID = try await claimSubtask(svc, taskID: taskID, owner: .devin)
        do {
            _ = try await svc.callTool("workshop_report_result", args: .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(subID.rawValue),
                "generation": .number(1),
                "summary": .string("done")]), principal: .engineer(.kimi))
            XCTFail("expected notOwner")
        } catch WorkshopError.notOwner {}
    }

    func testReportResultByOwnerMarksReview() async throws {
        let (svc, taskID) = try await service(participants: [.devin])
        let subID = try await claimSubtask(svc, taskID: taskID, owner: .devin)
        _ = try await svc.callTool("workshop_report_result", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(subID.rawValue),
            "summary": .string("all done"),
            "generation": .number(1),
            "artifact_ids": .array([.string("art_1")]),
            "validation": .array([.object(["command": .string("swift test"),
                                           "result": .string("pass")])]),
        ]), principal: .engineer(.devin))
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.subtasks[0].state, .review)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains { $0.body == "all done" })
    }

    func testRevisedResultAfterChangesRequestedGetsFreshReviewTarget() async throws {
        let (svc, taskID) = try await service(participants: [.devin, .kimi])
        let subID = try await claimSubtask(svc, taskID: taskID, owner: .devin)
        func report(_ summary: String) async throws -> Message {
            try await svc.toolReportResult(taskID: taskID, subtaskID: subID,
                summary: summary, artifactIDs: [], validation: [], generation: 1,
                principal: .engineer(.devin))
        }
        let original = try await report("original")
        let retry = try await report("original")
        XCTAssertEqual(retry.id, original.id)
        // A changed result while the subtask is still in review creates the
        // next revision rather than failing (revisions, not gating).
        let replaced = try await report("unreviewed replacement")
        XCTAssertNotEqual(replaced.id, original.id)
        let replacedPayload = try JSONDecoder().decode(
            JSONValue.self, from: Data(replaced.structured!.utf8))
        XCTAssertEqual(replacedPayload["revision"]?.intValue, 2)
        XCTAssertEqual(replacedPayload["supersedes"]?.stringValue,
                       original.id.rawValue)
        do {
            _ = try await svc.toolReportResult(taskID: taskID, subtaskID: subID,
                summary: "original", artifactIDs: [], validation: [], generation: 1,
                principal: .engineer(.kimi))
            XCTFail("even an idempotent retry requires ownership")
        } catch WorkshopError.notOwner {}
        // The superseded revision is no longer a valid review target.
        do {
            _ = try await svc.toolSubmitReview(taskID: taskID,
                proposalID: original.id.rawValue, severity: "low",
                disposition: "agree", body: "stale approval", evidence: nil,
                principal: .engineer(.kimi))
            XCTFail("reviewing a superseded revision is stale")
        } catch WorkshopError.staleResult {}
        _ = try await svc.toolSubmitReview(taskID: taskID,
            proposalID: replaced.id.rawValue, severity: "medium",
            disposition: "needs_changes", body: "revise", evidence: nil,
            principal: .engineer(.kimi))
        let revised = try await report("revised with evidence")
        XCTAssertNotEqual(revised.id, replaced.id)
        let revisedRetry = try await report("revised with evidence")
        XCTAssertEqual(revisedRetry.id, revised.id)
        let pending = try await svc.getTask(taskID)
        XCTAssertEqual(pending.subtasks[0].verification, "pending")
        do {
            _ = try await svc.toolSubmitReview(taskID: taskID,
                proposalID: replaced.id.rawValue, severity: "low",
                disposition: "agree", body: "stale approval", evidence: nil,
                principal: .engineer(.kimi))
            XCTFail("stale approval cannot accept a revised result")
        } catch WorkshopError.staleResult {}
        _ = try await svc.toolSubmitReview(taskID: taskID,
            proposalID: revised.id.rawValue, severity: "low",
            disposition: "agree", body: "verified revision", evidence: nil,
            principal: .engineer(.kimi))
        let done = try await svc.getTask(taskID)
        XCTAssertEqual(done.subtasks[0].verification, "passed")
        await svc.shutdown()
    }

    // MARK: - publish_artifact

    private func makeWorkspaceFile(_ taskID: TaskID, _ name: String,
                                   _ content: String) throws -> String {
        let ws = try WorkspaceManager.worktreePath(homeDir: dir, taskID: taskID)
        try content.write(toFile: ws + "/" + name, atomically: true, encoding: .utf8)
        return ws
    }

    func testPublishArtifactSuccess() async throws {
        let (svc, taskID) = try await service(participants: [.devin])
        _ = try makeWorkspaceFile(taskID, "out.txt", "hello artifact")
        let artifact = try await svc.callTool("workshop_publish_artifact",
            args: .object([
                "task_id": .string(taskID.rawValue),
                "path": .string("out.txt"),
                "description": .string("test")]),
            principal: .engineer(.devin))
        let a = try artifact.decode(as: Artifact.self)
        XCTAssertEqual(a.producer, "devin")
        XCTAssertEqual(a.contentHash.count, 64)
        let stored = dir + "/" + a.relativePath
        XCTAssertEqual(try String(contentsOfFile: stored), "hello artifact")
    }

    func testPublishArtifactRejectsTraversalAndSymlink() async throws {
        let (svc, taskID) = try await service(participants: [.devin])
        let ws = try makeWorkspaceFile(taskID, "out.txt", "x")
        // A secret outside the workspace.
        try "secret".write(toFile: dir + "/secret.txt", atomically: true,
                           encoding: .utf8)
        // A symlink inside the workspace pointing outside.
        try? FileManager.default.createSymbolicLink(
            atPath: ws + "/link.txt", withDestinationPath: dir + "/secret.txt")
        for path in ["../secret.txt", "/etc/passwd", "link.txt",
                     dir + "/secret.txt"] {
            do {
                _ = try await svc.callTool("workshop_publish_artifact",
                    args: .object([
                        "task_id": .string(taskID.rawValue),
                        "path": .string(path), "description": .string("x")]),
                    principal: .engineer(.devin))
                XCTFail("expected workspaceEscape for \(path)")
            } catch WorkshopError.workspaceEscape {}
        }
        // An absolute path that resolves inside the workspace is accepted.
        let artifact = try await svc.callTool("workshop_publish_artifact",
            args: .object([
                "task_id": .string(taskID.rawValue),
                "path": .string(ws + "/out.txt"), "description": .string("abs")]),
            principal: .engineer(.devin))
        XCTAssertEqual(try artifact.decode(as: Artifact.self).producer, "devin")
    }

    // MARK: - capacity

    func testCapacityReportsUnknown() async throws {
        let (svc, _) = try await service()
        let result = try await svc.callTool("workshop_get_capacity", args: .object([:]),
                                            principal: .engineer(.devin))
        for e in EngineerID.allCases {
            XCTAssertEqual(result[e.rawValue]?["remaining"]?.stringValue, "unknown")
        }
    }

    // MARK: - phase-gated tools

    /// All catalog tools are implemented since Phase 5; unknown names get
    /// methodNotFound, malformed create args get a decode/invalidRequest error.
    func testPhaseGatedToolsReturnMethodNotFound() async throws {
        let (svc, _) = try await service()
        do {
            _ = try await svc.callTool("workshop_fictional_tool",
                                       args: .object([:]),
                                       principal: .engineer(.devin))
            XCTFail("expected methodNotFound")
        } catch WorkshopError.methodNotFound {}
        do {
            _ = try await svc.callTool("workshop_create_task",
                                       args: .object([:]),
                                       principal: .engineer(.devin))
            XCTFail("expected a decoding/invalidRequest error")
        } catch WorkshopError.invalidRequest {}
    }

    // MARK: - wakeups (§5.4)

    /// Wait for a committed engineer reply beyond `minSeq` (wakeup turn ran).
    private func waitForEngineerReply(_ svc: CollaborationService, taskID: TaskID,
                                      engineer: EngineerID, minSeq: Int64,
                                      timeout: TimeInterval = 10) async -> Message? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let messages = (try? await svc.readMessages(taskID)) ?? []
            if let m = messages.first(where: {
                $0.author == .engineer(engineer) && $0.seq > minSeq
                    && $0.deliveryState == .committed && !$0.body.isEmpty
            }) { return m }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// Drive a full owner turn: enable dispatcher, then post a user message and
    /// verify the owner's wakeup reply appears (T10).
    func testUserReplyWakesOwner() async throws {
        let adapters = fakes()
        let svc = try CollaborationService(
            databasePath: dir + "/db.sqlite", adapters: adapters,
            dispatcherEnabled: true, homeDir: dir, wakeupCoalescence: .zero)
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "w1", title: "T", objective: "obj",
            phase: .execution, participants: [.devin]))
        await svc.start()
        await svc.awaitIdle()
        let followup = try await svc.postMessage(taskID: receipt.taskID,
                                                 body: "user followup",
                                                 principal: .user)
        let reply = await waitForEngineerReply(svc, taskID: receipt.taskID,
                                               engineer: .devin, minSeq: followup.seq)
        XCTAssertNotNil(reply, "user reply should wake the owner")
        await svc.shutdown()
    }

    /// @mention wakes exactly the mentioned participant, once (coalesced).
    func testMentionWakesMentionedEngineer() async throws {
        let adapters = fakes()
        let svc = try CollaborationService(
            databasePath: dir + "/db2.sqlite", adapters: adapters,
            dispatcherEnabled: false, homeDir: dir, wakeupCoalescence: .zero)
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "w2", title: "T", objective: "obj",
            phase: .execution, participants: [.devin, .kimi]))
        let kimiAdapter = adapters.first { $0.engineer == .kimi }!
        let devinAdapter = adapters.first { $0.engineer == .devin }!
        let before = kimiAdapter.turnCount
        _ = try await svc.postMessage(taskID: receipt.taskID,
                                      body: "@kimi can you check this?",
                                      principal: .engineer(.devin))
        let reply = await waitForEngineerReply(svc, taskID: receipt.taskID,
                                               engineer: .kimi, minSeq: 0)
        XCTAssertNotNil(reply, "mention should wake kimi")
        XCTAssertEqual(kimiAdapter.turnCount, before + 1)
        XCTAssertEqual(devinAdapter.turnCount, 0, "author is never woken")
        await svc.shutdown()
    }

    func testPendingPeerWakeupRunsAfterServiceRestart() async throws {
        let database = dir + "/restart-wakeup.sqlite"
        let first = try CollaborationService(
            databasePath: database, adapters: fakes(), dispatcherEnabled: false,
            homeDir: dir, wakeupCoalescence: .zero)
        let receipt = try await first.createTask(CreateTaskRequest(
            idempotencyKey: "restart-wakeup", title: "T", objective: "obj",
            phase: .execution, participants: [.devin, .kimi]))
        _ = try await first.insertWakeupForTest(taskID: receipt.taskID,
                                                engineer: .kimi, reason: "mention", state: "pending")
        await first.shutdown()

        let second = try CollaborationService(
            databasePath: database, adapters: fakes(), dispatcherEnabled: true,
            homeDir: dir, wakeupCoalescence: .zero)
        await second.start()
        let reply = await waitForEngineerReply(second, taskID: receipt.taskID,
                                               engineer: .kimi, minSeq: 0)
        XCTAssertNotNil(reply, "pending peer wakeup should resume after restart")
        await second.shutdown()
    }

    /// Engineer↔engineer messages without a mention wake nobody.
    func testUnmentionedPeerNotWoken() async throws {
        let adapters = fakes()
        let svc = try CollaborationService(
            databasePath: dir + "/db3.sqlite", adapters: adapters,
            dispatcherEnabled: false, homeDir: dir, wakeupCoalescence: .zero)
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "w3", title: "T", objective: "obj",
            phase: .execution, participants: [.devin, .kimi]))
        _ = try await svc.postMessage(taskID: receipt.taskID, body: "no mention",
                                      principal: .engineer(.devin))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(adapters.first { $0.engineer == .kimi }!.turnCount, 0)
        await svc.shutdown()
    }

    /// Loop bound: after N completed substantive engineer turns without a
    /// user message, further wakeups are suppressed and a system event is
    /// posted once (T11). Only `done` wakeups count — wait for the first
    /// turn to finish before posting the second.
    func testWakeupLoopBoundSuppresses() async throws {
        let (svc, taskID) = try await service(participants: [.devin, .kimi], loopBound: 1)
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi one",
                                      principal: .engineer(.devin))
        let replied = await waitForEngineerReply(svc, taskID: taskID,
                                                 engineer: .kimi, minSeq: 0)
        XCTAssertNotNil(replied)
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi two",
                                      principal: .engineer(.devin))
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent
                && $0.body == "Discussion round limit reached; waiting for user"
        })
    }

    // MARK: - checkpoint

    func testSaveCheckpoint() async throws {
        let (svc, taskID) = try await service(participants: [.kimi])
        let result = try await svc.callTool("workshop_save_checkpoint", args: .object([
            "task_id": .string(taskID.rawValue),
            "schema_version": .number(1),
            "objective": .string("halfway"),
            "completed": .array([]), "decisions": .array([]),
            "artifacts": .array([]), "validation": .array([]),
            "unresolved": .array([]), "next_action": .string("continue"),
            "last_read_message_seq": .number(0),
        ]), principal: .engineer(.kimi))
        XCTAssertNotNil(result["checkpoint_id"]?.intValue)
    }
}
