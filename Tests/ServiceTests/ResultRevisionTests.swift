import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-B4: result revisions, review binding to the latest revision, and the
/// turn-end-without-result nudge.
final class ResultRevisionTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-rr-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func makeService(adapters: [FakeAdapter], dispatcher: Bool = false)
        throws -> CollaborationService {
        let svc = try CollaborationService(
            databasePath: dir + "/db-\(UUID().uuidString).sqlite",
            adapters: adapters, dispatcherEnabled: dispatcher, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0)
        for adapter in adapters {
            adapter.toolRunner = { [weak svc] name, args, principal in
                guard let svc else { return .null }
                return try await svc.callTool(name, args: args, principal: principal)
            }
        }
        return svc
    }

    private func task(_ svc: CollaborationService,
                      participants: [EngineerID]) async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "do X",
            phase: .execution, participants: participants))
        return receipt.taskID
    }

    private func claim(_ svc: CollaborationService, taskID: TaskID,
                       owner: EngineerID) async throws -> Subtask {
        let sub = try await svc.getTask(taskID).subtasks[0]
        _ = try await svc.claimForTest(subtaskID: sub.id, owner: owner,
                                       expectedGeneration: sub.generation)
        return try await svc.getTask(taskID).subtasks[0]
    }

    @discardableResult
    private func report(_ svc: CollaborationService, taskID: TaskID,
                        sub: Subtask, summary: String) async throws -> Message {
        let result = try await svc.callTool("workshop_report_result", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(sub.id.rawValue),
            "summary": .string(summary),
            "generation": .number(Double(sub.generation)),
            "artifact_ids": .array([.string("a1")]),
            "validation": .array([.object(["command": .string("t"),
                                           "result": .string("pass")])]),
        ]), principal: .engineer(sub.ownerID!))
        return try result.decode(as: Message.self)
    }

    private func structured(_ m: Message) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self,
                                 from: Data(m.structured!.utf8))
    }

    private func waitFor(_ predicate: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await predicate()) == true { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func testReReportAfterNeedsChangesCreatesRevision2() async throws {
        let adapters = EngineerID.allCases.map {
            FakeAdapter(engineer: $0, delayPerDelta: .zero)
        }
        let svc = try makeService(adapters: adapters, dispatcher: true)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        // The initial unscripted owner turn must settle to working first so
        // report_result can transition working → verifying.
        let working = await waitFor {
            try await svc.getTask(taskID).task.state == .working }
        XCTAssertTrue(working)
        let sub = try await svc.getTask(taskID).subtasks[0]

        let r1 = try await report(svc, taskID: taskID, sub: sub, summary: "v1")
        XCTAssertEqual(try structured(r1)["revision"]?.intValue, 1)
        var detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.subtasks[0].state, .review)
        XCTAssertEqual(detail.task.state, .verifying)

        // Peer review requests changes on r1.
        _ = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(r1.id.rawValue),
            "severity": .string("medium"),
            "disposition": .string("needs_changes"),
            "body": .string("missing evidence")]), principal: .engineer(.kimi))
        detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.subtasks[0].state, .working)
        XCTAssertEqual(detail.task.state, .working)
        let changeWakeups = try await svc.wakeupsForTest(taskID)
        XCTAssertTrue(changeWakeups.contains {
            $0.engineerID == .devin && $0.reason == "changes_requested" })

        // Owner re-reports → revision 2, superseding r1.
        let r2 = try await report(svc, taskID: taskID, sub: sub, summary: "v2")
        XCTAssertNotEqual(r2.id, r1.id)
        let s2 = try structured(r2)
        XCTAssertEqual(s2["revision"]?.intValue, 2)
        XCTAssertEqual(s2["supersedes"]?.stringValue, r1.id.rawValue)
        detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.subtasks[0].state, .review)
        XCTAssertEqual(detail.task.state, .verifying)
        let allMessages = try await svc.readMessages(taskID)
        XCTAssertTrue(allMessages.contains {
            $0.kind == .systemEvent && $0.body.contains("revision 2") })

        // The needs_changes reviewer is woken to verify the new revision —
        // exactly once.
        let verifyWakeups = try await svc.wakeupsForTest(taskID).filter {
            $0.engineerID == .kimi && $0.reason == "verify_result:" + r2.id.rawValue
        }
        XCTAssertEqual(verifyWakeups.count, 1)

        // TaskDetail exposes the latest binding.
        detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.subtaskResults?[sub.id.rawValue]?.latestResultMessageID,
                       r2.id.rawValue)
        XCTAssertEqual(detail.subtaskResults?[sub.id.rawValue]?.resultRevision, 2)
        await svc.shutdown()
    }

    func testIdenticalRetryInReviewReturnsSameRevision() async throws {
        let svc = try makeService(adapters: [
            FakeAdapter(engineer: .devin, delayPerDelta: .zero)], dispatcher: true)
        let taskID = try await task(svc, participants: [.devin])
        await svc.start()
        let working = await waitFor {
            try await svc.getTask(taskID).task.state == .working }
        XCTAssertTrue(working)
        let sub = try await svc.getTask(taskID).subtasks[0]
        let r1 = try await report(svc, taskID: taskID, sub: sub, summary: "same")
        let r2 = try await report(svc, taskID: taskID, sub: sub, summary: "same")
        XCTAssertEqual(r1.id, r2.id)
        await svc.shutdown()
    }

    func testReviewOnSupersededResultIsStale() async throws {
        let svc = try makeService(adapters: [
            FakeAdapter(engineer: .devin, delayPerDelta: .zero),
            FakeAdapter(engineer: .kimi, delayPerDelta: .zero)], dispatcher: true)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        let working = await waitFor {
            try await svc.getTask(taskID).task.state == .working }
        XCTAssertTrue(working)
        let sub = try await svc.getTask(taskID).subtasks[0]
        let r1 = try await report(svc, taskID: taskID, sub: sub, summary: "v1")
        _ = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(r1.id.rawValue),
            "severity": .string("low"), "disposition": .string("needs_changes"),
            "body": .string("fix it")]), principal: .engineer(.kimi))
        let r2 = try await report(svc, taskID: taskID, sub: sub, summary: "v2")

        do {
            _ = try await svc.callTool("workshop_submit_review", args: .object([
                "task_id": .string(taskID.rawValue),
                "proposal_id": .string(r1.id.rawValue),
                "severity": .string("low"), "disposition": .string("agree"),
                "body": .string("lgtm")]), principal: .engineer(.kimi))
            XCTFail("expected staleResult")
        } catch let e as WorkshopError {
            XCTAssertEqual(e.rpcCode, -32008)
            XCTAssertTrue(e.message.contains(r2.id.rawValue))
        }

        let ok = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(r2.id.rawValue),
            "severity": .string("low"), "disposition": .string("agree"),
            "body": .string("lgtm")]), principal: .engineer(.kimi))
        let review = try ok.decode(as: Message.self)
        XCTAssertEqual(try structured(review)["result_revision"]?.intValue, 2)
        await svc.shutdown()
    }

    func testReviewOnPlainMessageRejectedBeforePosting() async throws {
        let svc = try makeService(adapters: [
            FakeAdapter(engineer: .devin, delayPerDelta: .zero),
            FakeAdapter(engineer: .kimi, delayPerDelta: .zero)])
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        let plain = try await svc.postMessage(taskID: taskID, body: "just words",
                                              principal: .engineer(.kimi))
        do {
            _ = try await svc.callTool("workshop_submit_review", args: .object([
                "task_id": .string(taskID.rawValue),
                "proposal_id": .string(plain.id.rawValue),
                "severity": .string("low"), "disposition": .string("agree"),
                "body": .string("lgtm")]), principal: .engineer(.kimi))
            XCTFail("expected invalidRequest")
        } catch WorkshopError.invalidRequest {}
        let messages = try await svc.readMessages(taskID)
        XCTAssertFalse(messages.contains { $0.kind == .review })
        await svc.shutdown()
    }

    func testUnscriptedTurnNudgesOnceAndStaysWorking() async throws {
        let adapters = [FakeAdapter(engineer: .devin, delayPerDelta: .zero)]
        let svc = try makeService(adapters: adapters, dispatcher: true)
        let taskID = try await task(svc, participants: [.devin])
        await svc.start()
        // First unscripted turn ends without a result → event + one nudge;
        // the nudge itself runs a second unscripted turn which must not
        // create another nudge.
        let settled = await waitFor { adapters[0].turnCount >= 2 }
        XCTAssertTrue(settled)
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.state, .working)
        let events = try await svc.readMessages(taskID)
        XCTAssertTrue(events.contains {
            $0.kind == .systemEvent
                && $0.body == "Owner turn ended without workshop_report_result; task remains working" })
        let nudges = try await svc.wakeupsForTest(taskID).filter {
            $0.engineerID == .devin && $0.reason == "report_requested" }
        XCTAssertEqual(nudges.count, 1)
        await svc.shutdown()
    }

    func testScriptedReportTurnVerifiesOnce() async throws {
        let adapters = [FakeAdapter(engineer: .devin, delayPerDelta: .zero)]
        let svc = try makeService(adapters: adapters, dispatcher: true)
        adapters[0].script = { context in
            guard let sub = context.subtask else { return [.text("no subtask")] }
            return [.toolCall("workshop_report_result", .object([
                "task_id": .string(context.task.id.rawValue),
                "subtask_id": .string(sub.id.rawValue),
                "summary": .string("done"),
                "generation": .number(Double(sub.generation))]))]
        }
        let taskID = try await task(svc, participants: [.devin])
        await svc.start()
        let done = await waitFor {
            try await svc.getTask(taskID).task.state == .verifying
        }
        XCTAssertTrue(done)
        let events = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent
                && $0.body == "Owner reported complete; verification pending" }
        XCTAssertEqual(events.count, 1)
        await svc.shutdown()
    }
}
