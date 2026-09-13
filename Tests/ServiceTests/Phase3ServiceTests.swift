import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// Phase 3 service tests: research/proposal policy (§5.3, T12), user approval
/// (T07/T08/T27-lite), allocation + disputes, proportional review (§5.5), task
/// actions, and the F1/F2 review fixes.
final class Phase3ServiceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-p3-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    /// Service with deadlines disabled and zero wakeup coalescence.
    private func makeService(adapters: [EngineerAdapter],
                             file: String = "db.sqlite") throws -> CollaborationService {
        try CollaborationService(
            databasePath: dir + "/" + file, adapters: adapters,
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0)
    }

    private func researchTask(_ svc: CollaborationService,
                              participants: [EngineerID] = EngineerID.allCases)
        async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "R", objective: "decide X",
            phase: .researchProposal, participants: participants))
        return receipt.taskID
    }

    private func submitProposal(_ svc: CollaborationService, taskID: TaskID,
                                _ engineer: EngineerID, title: String) async throws {
        _ = try await svc.callTool("workshop_submit_proposal", args: .object([
            "task_id": .string(taskID.rawValue),
            "title": .string(title),
            "summary": .string("\(engineer.rawValue) summary"),
            "approach": .string("\(engineer.rawValue) approach"),
            "proposed_ownership": .array([.object([
                "subtask_title": .string("Write note"),
                "acceptance_criteria": .array([.string("note exists")]),
                "proposed_owner": .string(engineer.rawValue),
                "rationale": .string("fit"),
            ])]),
        ]), principal: .engineer(engineer))
    }

    private func publishedProposalIDs(_ svc: CollaborationService,
                                      taskID: TaskID) async throws -> [String] {
        try await svc.listProposals(taskID)
            .filter { $0.visibility == "published" }.map(\.id)
    }

    private func submitReview(_ svc: CollaborationService, taskID: TaskID,
                              _ engineer: EngineerID, proposalID: String,
                              disposition: String = "agree") async throws {
        _ = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(proposalID),
            "severity": .string("low"),
            "disposition": .string(disposition),
            "body": .string("review by \(engineer.rawValue)"),
        ]), principal: .engineer(engineer))
    }

    private func submitReport(_ svc: CollaborationService, taskID: TaskID,
                              principal: Principal = .engineer(.devin)) async throws {
        _ = try await svc.callTool("workshop_submit_report", args: .object([
            "task_id": .string(taskID.rawValue),
            "recommendation": .string("do the thing"),
            "proposed_ownership": .array([
                .object(["subtask_title": .string("Write note"),
                         "acceptance_criteria": .array([.string("note exists")]),
                         "proposed_owner": .string("kimi"),
                         "rationale": .string("fast"), "risk": .string("normal")]),
                .object(["subtask_title": .string("Publish note"),
                         "acceptance_criteria": .array([.string("published")]),
                         "proposed_owner": .string("deepseek"),
                         "rationale": .string("fit"), "risk": .string("high"),
                         "depends_on": .array([.string("Write note")])]),
            ]),
        ]), principal: principal)
    }

    private func waitFor(_ timeout: TimeInterval = 10,
                         _ predicate: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await predicate()) == true { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    // MARK: - Proposals (T12)

    func testDraftProposalsInvisibleToPeers() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await researchTask(svc)
        await svc.start()
        try await submitProposal(svc, taskID: taskID, .devin, title: "Devin plan")
        try await submitProposal(svc, taskID: taskID, .kimi, title: "Kimi plan")

        // kimi sees only its own draft — Devin's is private (T12).
        let kimiView = try await svc.callTool("workshop_read_proposals",
            args: .object(["task_id": .string(taskID.rawValue)]),
            principal: .engineer(.kimi))
        let proposals = try kimiView.decode(as: [Proposal].self)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].author, .kimi)

        // get_task exposes counts only.
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.draftProposalCount, 2)
        XCTAssertEqual(detail.publishedProposalCount, 0)
        let messages = try await svc.readMessages(taskID)
        XCTAssertFalse(messages.contains { $0.body.contains("Devin plan") })
        await svc.shutdown()
    }

    func testPublishTogetherRecordsMissing() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await researchTask(svc)
        await svc.start()
        try await submitProposal(svc, taskID: taskID, .devin, title: "Devin plan")
        try await submitProposal(svc, taskID: taskID, .kimi, title: "Kimi plan")
        try await svc.publishProposals(taskID)

        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.state, .reviewingProposal)
        XCTAssertEqual(detail.publishedProposalCount, 2)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent && $0.body.contains("missing: deepseek") })
        // One cross_review wakeup per participant.
        let reviews = try await svc.wakeupsForTest(taskID)
            .filter { $0.reason == "cross_review" }
        XCTAssertEqual(reviews.count, 3)
        // Peers now see the published proposals.
        let kimiView = try await svc.callTool("workshop_read_proposals",
            args: .object(["task_id": .string(taskID.rawValue)]),
            principal: .engineer(.kimi))
        XCTAssertEqual(try kimiView.decode(as: [Proposal].self).count, 2)
        await svc.shutdown()
    }

    func testConsolidateWakesDevinOnly() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await researchTask(svc)
        await svc.start()
        for e in EngineerID.allCases {
            try await submitProposal(svc, taskID: taskID, e, title: "\(e) plan")
        }
        // Third proposal auto-publishes (all available participants drafted).
        let ids = try await publishedProposalIDs(svc, taskID: taskID)
        XCTAssertEqual(ids.count, 3)
        for (i, e) in EngineerID.allCases.enumerated() {
            try await submitReview(svc, taskID: taskID, e,
                                   proposalID: ids[(i + 1) % ids.count])
        }
        let consolidate = try await svc.wakeupsForTest(taskID)
            .filter { $0.reason == "consolidate" }
        XCTAssertEqual(consolidate.count, 1)
        XCTAssertEqual(consolidate[0].engineerID, .devin)
        await svc.shutdown()
    }

    func testDevinUnavailableConsolidationWaits() async throws {
        let adapters = fakes()
        adapters.first { $0.engineer == .devin }!
            .setHealth(.unavailable("devin binary missing"))
        let svc = try makeService(adapters: adapters)
        let taskID = try await researchTask(svc)
        await svc.start()
        // Only kimi + deepseek are available; once every *available*
        // participant has a draft, proposals publish.
        try await submitProposal(svc, taskID: taskID, .kimi, title: "Kimi plan")
        try await submitProposal(svc, taskID: taskID, .deepseek, title: "DS plan")
        let ids = try await publishedProposalIDs(svc, taskID: taskID)
        XCTAssertEqual(ids.count, 2)
        try await submitReview(svc, taskID: taskID, .kimi, proposalID: ids[0])
        try await submitReview(svc, taskID: taskID, .deepseek, proposalID: ids[1])

        let seen = await waitFor {
            let messages = try await svc.readMessages(taskID)
            return messages.contains {
                $0.kind == .systemEvent
                    && $0.body.contains("Consolidated report waits for Devin Fusion")
            }
        }
        XCTAssertTrue(seen, "expected the unavailable-arbiter system event")
        let consolidate = try await svc.wakeupsForTest(taskID)
            .filter { $0.reason == "consolidate" }
        XCTAssertEqual(consolidate.map(\.engineerID), [.devin])
        XCTAssertEqual(consolidate[0].state, "suppressed")
        await svc.shutdown()
    }

    // MARK: - Approval gate (T07/T08/T27-lite)

    func testT07ImplementationToolsGatedBeforeApproval() async throws {
        let adapters = fakes()
        let svc = try makeService(adapters: adapters)
        let taskID = try await researchTask(svc)
        await svc.start()
        let subID = try await svc.getTask(taskID).subtasks[0].id
        for (name, args) in [
            ("workshop_claim_subtask", JSONValue.object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(subID.rawValue)])),
            ("workshop_assign_subtask", .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(subID.rawValue),
                "owner": .string("kimi")])),
            ("workshop_report_result", .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(subID.rawValue),
                "summary": .string("x")])),
            ("workshop_publish_artifact", .object([
                "task_id": .string(taskID.rawValue),
                "path": .string("f.txt"), "description": .string("x")])),
            ("workshop_propose_subtask", .object([
                "task_id": .string(taskID.rawValue), "title": .string("extra")])),
        ] {
            do {
                _ = try await svc.callTool(name, args: args,
                                           principal: .engineer(.devin))
                XCTFail("expected approvalRequired for \(name)")
            } catch WorkshopError.approvalRequired {}
        }
        // No owner-execution turn was ever dispatched.
        for adapter in adapters {
            XCTAssertTrue(adapter.receivedContexts.allSatisfy { $0.wakeReason != nil },
                          "execution turn dispatched before approval")
        }
        await svc.shutdown()
    }

    private func approvedResearchTask(_ svc: CollaborationService)
        async throws -> TaskID {
        let taskID = try await researchTask(svc)
        await svc.start()
        for e in EngineerID.allCases {
            try await submitProposal(svc, taskID: taskID, e, title: "\(e) plan")
        }
        let ids = try await publishedProposalIDs(svc, taskID: taskID)
        for (i, e) in EngineerID.allCases.enumerated() {
            try await submitReview(svc, taskID: taskID, e,
                                   proposalID: ids[(i + 1) % ids.count])
        }
        try await submitReport(svc, taskID: taskID)
        try await svc.approveArchitecture(taskID: taskID, reportRevision: 1,
                                          scope: nil, principal: .user)
        return taskID
    }

    func testApproveCreatesSubtasksAndWakesDevin() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await approvedResearchTask(svc)
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.state, .ready)
        XCTAssertEqual(detail.task.approvalRevision, 1)
        XCTAssertEqual(detail.task.reportRevision, 1)
        let titles = detail.subtasks.map(\.title)
        XCTAssertTrue(titles.contains("Write note"))
        XCTAssertTrue(titles.contains("Publish note"))
        let publish = detail.subtasks.first { $0.title == "Publish note" }!
        XCTAssertEqual(publish.risk, "high")
        let write = detail.subtasks.first { $0.title == "Write note" }!
        XCTAssertEqual(publish.dependencies, [write.id.rawValue])
        let wakeups = try await svc.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups.contains {
            $0.engineerID == .devin && $0.reason == "allocate" })
        await svc.shutdown()
    }

    func testStaleRevisionAndEngineerApprovalRejected() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await researchTask(svc)
        await svc.start()
        try await submitProposal(svc, taskID: taskID, .devin, title: "d")
        try await submitProposal(svc, taskID: taskID, .kimi, title: "k")
        try await submitProposal(svc, taskID: taskID, .deepseek, title: "s")
        try await submitReport(svc, taskID: taskID)
        do {
            try await svc.approveArchitecture(taskID: taskID, reportRevision: 7,
                                              scope: nil, principal: .user)
            XCTFail("expected staleRevision")
        } catch WorkshopError.staleRevision {}
        do {
            try await svc.approveArchitecture(taskID: taskID, reportRevision: 1,
                                              scope: nil, principal: .engineer(.devin))
            XCTFail("expected userAuthorityRequired")
        } catch WorkshopError.userAuthorityRequired {}
        // T27-lite: an engineer merely saying "approved" changes nothing.
        _ = try await svc.postMessage(taskID: taskID, body: "approved",
                                      principal: .engineer(.kimi))
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.state, .awaitingArchitectureApproval)
        XCTAssertNil(detail.task.approvalRevision)
        await svc.shutdown()
    }

    func testT08NewRevisionInvalidatesApproval() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await approvedResearchTask(svc)
        try await submitReport(svc, taskID: taskID)  // revision 2
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.reportRevision, 2)
        XCTAssertNil(detail.task.approvalRevision, "r1 approval must be revoked")
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent
                && $0.body.contains("no longer authorizes new work") })
        // Implementation tools are gated again.
        let sub = detail.subtasks.first { $0.title == "Write note" }!
        do {
            _ = try await svc.callTool("workshop_assign_subtask", args: .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(sub.id.rawValue),
                "owner": .string("kimi")]), principal: .engineer(.devin))
            XCTFail("expected approvalRequired after invalidation")
        } catch WorkshopError.approvalRequired {}
        await svc.shutdown()
    }

    // MARK: - Allocation & disputes

    func testAssignDependencyGatingCASAndDispute() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await approvedResearchTask(svc)
        let detail = try await svc.getTask(taskID)
        let write = detail.subtasks.first { $0.title == "Write note" }!
        let publish = detail.subtasks.first { $0.title == "Publish note" }!

        // Dependency not done → blockedByDependency.
        do {
            _ = try await svc.callTool("workshop_assign_subtask", args: .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(publish.id.rawValue),
                "owner": .string("deepseek")]), principal: .engineer(.devin))
            XCTFail("expected blockedByDependency")
        } catch WorkshopError.blockedByDependency {}

        // Kimi cannot assign (arbiter authority, §5.3).
        do {
            _ = try await svc.callTool("workshop_assign_subtask", args: .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(write.id.rawValue),
                "owner": .string("kimi")]), principal: .engineer(.kimi))
            XCTFail("expected userAuthorityRequired")
        } catch WorkshopError.userAuthorityRequired {}

        // Devin assigns; generation CAS.
        _ = try await svc.callTool("workshop_assign_subtask", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(write.id.rawValue),
            "owner": .string("kimi"),
            "rationale": .string("kimi is fastest on notes"),
            "expected_generation": .number(0)]), principal: .engineer(.devin))
        let after = try await svc.getTask(taskID)
        XCTAssertEqual(after.subtasks.first { $0.id == write.id }?.ownerID, .kimi)
        let decisions = try await svc.listDecisions(taskID)
        XCTAssertTrue(decisions.contains {
            $0.kind == "allocation" && $0.body.contains("kimi is fastest") })
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains { $0.kind == .assignment })
        let wakeups = try await svc.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups.contains {
            $0.engineerID == .kimi && $0.reason == "assigned" })

        // Second assignment of an owned subtask fails the CAS.
        do {
            _ = try await svc.callTool("workshop_assign_subtask", args: .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(write.id.rawValue),
                "owner": .string("deepseek")]), principal: .engineer(.devin))
            XCTFail("expected already-owned failure")
        } catch WorkshopError.invalidRequest {}

        // Kimi disputes; Devin is woken to resolve.
        _ = try await svc.callTool("workshop_dispute_assignment", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(write.id.rawValue),
            "body": .string("I lack context on this note")]),
            principal: .engineer(.kimi))
        let decisions2 = try await svc.listDecisions(taskID)
        XCTAssertTrue(decisions2.contains { $0.kind == "dispute" })
        let wakeups2 = try await svc.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups2.contains {
            $0.engineerID == .devin && $0.reason == "dispute" })
        await svc.shutdown()
    }

    // MARK: - Proportional review (§5.5)

    private func assignAndReport(_ svc: CollaborationService, taskID: TaskID)
        async throws -> String {
        let write = try await svc.getTask(taskID).subtasks
            .first { $0.title == "Write note" }!
        _ = try await svc.callTool("workshop_assign_subtask", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(write.id.rawValue),
            "owner": .string("kimi")]), principal: .engineer(.devin))
        _ = try await svc.callTool("workshop_report_result", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(write.id.rawValue),
            "generation": .number(1),
            "summary": .string("note written")]), principal: .engineer(.kimi))
        let verify = try await svc.wakeupsForTest(taskID)
            .filter { $0.reason.hasPrefix("verify_result") }
        XCTAssertEqual(verify.count, 1)
        XCTAssertEqual(verify[0].engineerID, .devin)
        return String(verify[0].reason.dropFirst("verify_result:".count))
    }

    func testProportionalReviewVerifiesAndCompletes() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await approvedResearchTask(svc)
        let resultMessageID = try await assignAndReport(svc, taskID: taskID)
        _ = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(resultMessageID),
            "severity": .string("low"),
            "disposition": .string("agree"),
            "body": .string("verified the note artifact")]),
            principal: .engineer(.devin))
        let after = try await svc.getTask(taskID)
        let done = after.subtasks.first { $0.title == "Write note" }!
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.verification, "passed")
        await svc.shutdown()
    }

    func testNeedsChangesReturnsToOwner() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await approvedResearchTask(svc)
        let resultMessageID = try await assignAndReport(svc, taskID: taskID)
        _ = try await svc.callTool("workshop_submit_review", args: .object([
            "task_id": .string(taskID.rawValue),
            "proposal_id": .string(resultMessageID),
            "severity": .string("medium"),
            "disposition": .string("needs_changes"),
            "body": .string("note is missing sources")]),
            principal: .engineer(.devin))
        let after = try await svc.getTask(taskID)
        let sub = after.subtasks.first { $0.title == "Write note" }!
        XCTAssertEqual(sub.state, .working)
        XCTAssertEqual(sub.verification, "changes_requested")
        let wakeups = try await svc.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups.contains {
            $0.engineerID == .kimi && $0.reason == "changes_requested" })
        await svc.shutdown()
    }

    // MARK: - Task actions

    /// Drive an execution task whose owner turn hangs until cancelled.
    private func hangingTask()
        async throws -> (CollaborationService, TaskID) {
        let adapters = [FakeAdapter(engineer: .devin, delayPerDelta: .zero)]
        let svc = try CollaborationService(
            databasePath: dir + "/hang-\(UUID().uuidString).sqlite",
            adapters: adapters, dispatcherEnabled: true, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0)
        for a in adapters {
            a.script = { _ in [.waitForCancel] }
            a.toolRunner = { name, args, principal in
                try await svc.callTool(name, args: args, principal: principal)
            }
        }
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "H", objective: "work",
            phase: .execution, participants: [.devin]))
        await svc.start()
        return (svc, receipt.taskID)
    }

    func testPauseCancelsRunningTurn() async throws {
        let (svc, taskID) = try await hangingTask()
        let working = await waitFor {
            let d = try await svc.getTask(taskID)
            return d.task.state == .working && !d.runningEngineers.isEmpty
        }
        XCTAssertTrue(working)
        try await svc.pauseTask(taskID: taskID, principal: .user)
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.state, .paused)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.body.contains("Pause requested")
                && $0.body.contains("cancellation requested") })
        XCTAssertTrue(messages.contains {
            $0.body.contains("cancellation acknowledged") })
        await svc.shutdown()
    }

    func testCancelWhileRunningRequestsThenCompletes() async throws {
        let (svc, taskID) = try await hangingTask()
        let working = await waitFor {
            let d = try await svc.getTask(taskID)
            return d.task.state == .working && !d.runningEngineers.isEmpty
        }
        XCTAssertTrue(working)
        try await svc.cancelTask(taskID: taskID, principal: .user)
        let cancelled = await waitFor {
            try await svc.getTask(taskID).task.state == .cancelled
        }
        XCTAssertTrue(cancelled)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains { $0.body == "Cancellation requested" })
        XCTAssertTrue(messages.contains { $0.body == "Cancellation completed" })
        let decisions = try await svc.listDecisions(taskID)
        XCTAssertTrue(decisions.contains { $0.kind == "cancellation" })
        await svc.shutdown()
    }

    func testEscalateThenConvertToResearch() async throws {
        let (svc, taskID) = try await hangingTask()
        let working = await waitFor {
            try await svc.getTask(taskID).task.state == .working
        }
        XCTAssertTrue(working)
        _ = try await svc.callTool("workshop_escalate_task", args: .object([
            "task_id": .string(taskID.rawValue),
            "reason": .string("scope is ambiguous")]), principal: .engineer(.devin))
        var detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.state, .paused)
        let decisions = try await svc.listDecisions(taskID)
        XCTAssertTrue(decisions.contains { $0.kind == "escalation" })
        try await svc.convertToResearch(taskID: taskID, principal: .user)
        detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.task.phase, .researchProposal)
        XCTAssertEqual(detail.task.state, .researching)
        let wakeups = try await svc.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups.contains { $0.reason == "research_proposal" })
        await svc.shutdown()
    }

    // MARK: - F1 ordering / F2 recovery wording

    func testToolMessageOrdersBeforeStreamedReply() async throws {
        let adapters = [FakeAdapter(engineer: .devin, delayPerDelta: .zero)]
        let svc = try CollaborationService(
            databasePath: dir + "/f1.sqlite", adapters: adapters,
            dispatcherEnabled: true, homeDir: dir, wakeupCoalescence: .zero,
            researchDeadline: 0, reviewDeadline: 0)
        let devin = adapters[0]
        devin.script = { context in
            [.toolCall("workshop_post_message", .object([
                "task_id": .string(context.task.id.rawValue),
                "body": .string("TOOL_POSTED_MARKER")])),
             .text("STREAMED_REPLY_MARKER")]
        }
        devin.toolRunner = { name, args, principal in
            try await svc.callTool(name, args: args, principal: principal)
        }
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "f1", title: "F1", objective: "order",
            phase: .execution, participants: [.devin]))
        await svc.start()
        let done = await waitFor {
            try await svc.getTask(receipt.taskID).task.state == .verifying
        }
        XCTAssertTrue(done)
        let messages = try await svc.readMessages(receipt.taskID)
        let tool = messages.first { $0.body == "TOOL_POSTED_MARKER" }
        let reply = messages.first { $0.body == "STREAMED_REPLY_MARKER" }
        XCTAssertNotNil(tool); XCTAssertNotNil(reply)
        if let tool, let reply {
            XCTAssertLessThan(tool.seq, reply.seq,
                              "tool message must precede the streamed reply")
        }
        await svc.shutdown()
    }

    /// A tool-only turn commits no empty placeholder row (Phase 5 polish).
    func testToolOnlyTurnLeavesNoEmptyMessage() async throws {
        let adapters = [FakeAdapter(engineer: .devin, delayPerDelta: .zero)]
        let svc = try CollaborationService(
            databasePath: dir + "/toolonly.sqlite", adapters: adapters,
            dispatcherEnabled: true, homeDir: dir, wakeupCoalescence: .zero,
            researchDeadline: 0, reviewDeadline: 0)
        adapters[0].script = { context in
            [.toolCall("workshop_post_message", .object([
                "task_id": .string(context.task.id.rawValue),
                "body": .string("TOOL_ONLY_MARKER")]))]
        }
        adapters[0].toolRunner = { name, args, principal in
            try await svc.callTool(name, args: args, principal: principal)
        }
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "toolonly", title: "T", objective: "o",
            phase: .execution, participants: [.devin]))
        await svc.start()
        let done = await waitFor {
            try await svc.getTask(receipt.taskID).task.state == .verifying
        }
        XCTAssertTrue(done)
        let messages = try await svc.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains { $0.body == "TOOL_ONLY_MARKER" })
        XCTAssertFalse(messages.contains {
            $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        await svc.shutdown()
    }

    func testRecoveryMessageReflectsOutcome() async throws {
        // Case 1: task was working → blocked.
        let svcA = try makeService(adapters: fakes(), file: "ra.sqlite")
        _ = try await svcA.createTask(CreateTaskRequest(
            idempotencyKey: "ra", title: "A", objective: "o",
            phase: .execution, participants: [.devin]))
        try await svcA.insertStreamingMessageForTest(forceWorking: true)
        await svcA.start()
        var messages = try await svcA.readMessages(
            (try await svcA.listTasks())[0].id)
        XCTAssertTrue(messages.contains {
            $0.body.contains("task blocked pending reconciliation") })
        await svcA.shutdown()

        // Case 2: task was queued → honest "task remains" wording.
        let svcB = try makeService(adapters: fakes(), file: "rb.sqlite")
        _ = try await svcB.createTask(CreateTaskRequest(
            idempotencyKey: "rb", title: "B", objective: "o",
            phase: .execution, participants: [.devin]))
        try await svcB.insertStreamingMessageForTest(forceWorking: false)
        await svcB.start()
        messages = try await svcB.readMessages((try await svcB.listTasks())[0].id)
        XCTAssertTrue(messages.contains {
            $0.body.contains("task remains queued") })
        XCTAssertFalse(messages.contains {
            $0.body.contains("blocked pending reconciliation") })
        await svcB.shutdown()
    }
}
