import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// Phase 4 service tests: durability, leases/fencing (T05), idempotent
/// recovery (T06), checkpoints, capacity (T13/T14), cancellation (T23),
/// restart/sleep-wake (T29), resource leases (T24), storage guard (T30),
/// redaction (T32), pagination (T31), provider-unavailable (T15), outbox
/// cursors (§8.5), backup (T38).
final class Phase4ServiceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-p4-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(adapters: [EngineerAdapter],
                             file: String = "db.sqlite",
                             capacityPolicies: [EngineerID: CapacityPolicy] = [:],
                             requireKnownCapacity: Bool = false,
                             freeSpaceBytes: (@Sendable () -> Int64)? = nil,
                             now: @escaping () -> Date = Date.init)
        throws -> CollaborationService {
        let svc = try CollaborationService(
            databasePath: dir + "/" + file, adapters: adapters,
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0,
            capacityPolicies: capacityPolicies,
            requireKnownCapacity: requireKnownCapacity,
            freeSpaceBytes: freeSpaceBytes, now: now)
        for adapter in adapters.compactMap({ $0 as? FakeAdapter }) {
            adapter.toolRunner = { [weak svc] name, args, principal in
                guard let svc else { return .null }
                return try await svc.callTool(name, args: args, principal: principal)
            }
        }
        return svc
    }

    private func task(_ svc: CollaborationService,
                      participants: [EngineerID] = EngineerID.allCases)
        async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "do X",
            phase: .execution, participants: participants))
        return receipt.taskID
    }

    private func claim(_ svc: CollaborationService, taskID: TaskID,
                       owner: EngineerID) async throws -> Subtask {
        let detail = try await svc.getTask(taskID)
        let sub = detail.subtasks[0]
        _ = try await svc.claimForTest(subtaskID: sub.id, owner: owner,
                                       expectedGeneration: sub.generation)
        return try await svc.getTask(taskID).subtasks[0]
    }

    private func checkpointBody(_ seq: Int64 = 0) -> [String: JSONValue] {
        ["schema_version": .number(1), "objective": .string("o"),
         "completed": .array([]), "decisions": .array([]),
         "artifacts": .array([]), "validation": .array([]),
         "unresolved": .array([]), "next_action": .string("continue"),
         "last_read_message_seq": .number(Double(seq))]
    }

    private func systemEvents(_ svc: CollaborationService, _ taskID: TaskID)
        async throws -> [String] {
        try await svc.readMessages(taskID, limit: 2000)
            .filter { $0.kind == .systemEvent }.map(\.body)
    }

    private func workspaceFile(_ svc: CollaborationService, _ taskID: TaskID,
                               _ name: String, _ body: String) throws -> String {
        let ws = try WorkspaceManager.worktreePath(homeDir: dir, taskID: taskID)
        try FileManager.default.createDirectory(atPath: ws,
                                                withIntermediateDirectories: true)
        try body.write(toFile: ws + "/" + name, atomically: true, encoding: .utf8)
        return name
    }

    // MARK: - §8.5 outbox cursors

    func testOutboxDeliveryCursorAndDedup() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        var seen: Set<Int64> = []
        let stream = await svc.makeEventStream()
        // Drive a broadcast by posting a message.
        _ = try await svc.postMessage(taskID: taskID, body: "hello",
                                      principal: .user)
        var iter = stream.makeAsyncIterator()
        if let event = await iter.next() {
            // Client dedupes by seq — at-least-once delivery.
            XCTAssertFalse(seen.contains(event.seq))
            seen.insert(event.seq)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 1)
        // Service cursor recorded and pending broadcast rows delivered.
        let cursor = try await svc.outboxCursorForTest("service")
        XCTAssertGreaterThan(cursor, 0)
        let pending = try await svc.pendingBroadcastForTest()
        XCTAssertTrue(pending.isEmpty, "no broadcast row stays pending forever")
    }

    // MARK: - T05 fencing + leases

    func testT05StaleGenerationFenced() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        let sub = try await claim(svc, taskID: taskID, owner: .devin)
        XCTAssertEqual(sub.generation, 1)

        // Reassign to kimi (user authority) → generation 2.
        try await svc.reassignSubtask(subtaskID: sub.id, newOwner: .kimi,
                                      principal: .user)
        let after = try await svc.getTask(taskID).subtasks[0]
        XCTAssertEqual(after.ownerID, .kimi)
        XCTAssertEqual(after.generation, 2)

        // Stale devin report at generation 1 → fenced -32004.
        do {
            _ = try await svc.callTool("workshop_report_result", args: .object([
                "task_id": .string(taskID.rawValue),
                "subtask_id": .string(sub.id.rawValue),
                "generation": .number(1),
                "summary": .string("stale work")]),
                principal: .engineer(.devin))
            XCTFail("expected staleGeneration")
        } catch let error as WorkshopError {
            XCTAssertEqual(error.rpcCode, -32004)
        }

        // Stale artifact publish → quarantined under fenced/, refused.
        _ = try workspaceFile(svc, taskID, "stale.txt", "old work")
        do {
            _ = try await svc.callTool("workshop_publish_artifact", args: .object([
                "task_id": .string(taskID.rawValue),
                "path": .string("stale.txt"), "description": .string("old"),
                "generation": .number(1)]), principal: .engineer(.devin))
            XCTFail("expected staleGeneration")
        } catch let error as WorkshopError {
            XCTAssertEqual(error.rpcCode, -32004)
        }
        let fenced = dir + "/artifacts/" + taskID.rawValue + "/fenced"
        let contents = try FileManager.default.contentsOfDirectory(atPath: fenced)
        XCTAssertEqual(contents.count, 1)
        // Never merged into the normal artifact set.
        let artifacts = try await svc.listArtifacts(taskID)
        XCTAssertTrue(artifacts.isEmpty, "fenced artifact must not appear")
        let events = try await systemEvents(svc, taskID)
        XCTAssertTrue(events.contains {
            $0.contains("Fenced stale result from Devin Fusion (generation 1, current 2)")
        })
        // Current owner's work untouched: kimi reports at gen 2 fine.
        _ = try await svc.callTool("workshop_report_result", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(sub.id.rawValue),
            "generation": .number(2),
            "summary": .string("current work")]),
            principal: .engineer(.kimi))
    }

    func testLeaseSweeperBlocksExpiredWithoutRunningTurn() async throws {
        var now = Date()
        let svc = try makeService(adapters: fakes(), now: { now })
        let taskID = try await task(svc)
        let sub = try await claim(svc, taskID: taskID, owner: .devin)
        // Advance past the 5-minute lease.
        now = now.addingTimeInterval(400)
        await svc.sweepExpiredLeases()
        let after = try await svc.getTask(taskID).subtasks[0]
        XCTAssertEqual(after.state, .blocked)
        let events = try await systemEvents(svc, taskID)
        XCTAssertTrue(events.contains {
            $0.contains("Lease for Devin Fusion expired (generation 1)")
                && $0.contains("reconciliation required before reassignment")
        })
    }

    // MARK: - T06 idempotency + interrupted turn

    func testT06ArtifactIdempotentAndInterruptedResume() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        _ = try await claim(svc, taskID: taskID, owner: .devin)
        _ = try workspaceFile(svc, taskID, "out.txt", "payload")
        let a1 = try await svc.callTool("workshop_publish_artifact", args: .object([
            "task_id": .string(taskID.rawValue), "path": .string("out.txt"),
            "description": .string("d"), "generation": .number(1)]),
            principal: .engineer(.devin)).decode(as: Artifact.self)
        // Duplicate publication returns the same row.
        let a2 = try await svc.callTool("workshop_publish_artifact", args: .object([
            "task_id": .string(taskID.rawValue), "path": .string("out.txt"),
            "description": .string("d"), "generation": .number(1)]),
            principal: .engineer(.devin)).decode(as: Artifact.self)
        XCTAssertEqual(a1.id, a2.id)
        let artifacts = try await svc.listArtifacts(taskID)
        XCTAssertEqual(artifacts.count, 1)

        // report_result idempotent on (subtask, generation).
        let sub = try await svc.getTask(taskID).subtasks[0]
        let r1 = try await svc.callTool("workshop_report_result", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(sub.id.rawValue),
            "generation": .number(1), "summary": .string("done")]),
            principal: .engineer(.devin)).decode(as: Message.self)
        let r2 = try await svc.callTool("workshop_report_result", args: .object([
            "task_id": .string(taskID.rawValue),
            "subtask_id": .string(sub.id.rawValue),
            "generation": .number(1), "summary": .string("done")]),
            principal: .engineer(.devin)).decode(as: Message.self)
        XCTAssertEqual(r1.id, r2.id)

        // Simulate a crash: running turn row + a valid checkpoint → restart
        // wakes the owner with resume_from_checkpoint.
        _ = try await svc.callTool("workshop_save_checkpoint", args: .object(
            ["task_id": .string(taskID.rawValue)]
                .merging(checkpointBody()) { $1 }),
            principal: .engineer(.devin))
        try await svc.insertTurnForTest(taskID: taskID, subtaskID: sub.id,
                                        engineer: .devin, generation: 1)
        let svc2 = try makeService(adapters: fakes())
        await svc2.reconcileOnStart()
        let turns = try await svc2.turnsForTest(taskID)
        XCTAssertEqual(turns.first?.state, "interrupted")
        let wakeups = try await svc2.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups.contains {
            $0.engineerID == .devin && $0.reason == "resume_from_checkpoint"
        })
        let events = try await systemEvents(svc2, taskID)
        XCTAssertTrue(events.contains { $0.contains("Resuming Devin Fusion from checkpoint") })
    }

    func testInterruptedTurnWithoutCheckpointBlocks() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        let sub = try await claim(svc, taskID: taskID, owner: .devin)
        try await svc.insertTurnForTest(taskID: taskID, subtaskID: sub.id,
                                        engineer: .devin, generation: 1)
        let svc2 = try makeService(adapters: fakes())
        await svc2.reconcileOnStart()
        let after = try await svc2.getTask(taskID).subtasks[0]
        XCTAssertEqual(after.state, .blocked)
        let events = try await systemEvents(svc2, taskID)
        XCTAssertTrue(events.contains { $0.contains("no valid checkpoint") })
    }

    // MARK: - Checkpoints

    func testCheckpointValidation() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        // Missing keys rejected.
        do {
            _ = try await svc.callTool("workshop_save_checkpoint", args: .object([
                "task_id": .string(taskID.rawValue), "schema_version": .number(1)]),
                principal: .engineer(.devin))
            XCTFail("missing keys must fail")
        } catch WorkshopError.invalidRequest(_) {}
        // >64 KiB rejected.
        var big = checkpointBody()
        big["objective"] = .string(String(repeating: "x", count: 70 * 1024))
        do {
            _ = try await svc.callTool("workshop_save_checkpoint", args: .object(
                ["task_id": .string(taskID.rawValue)].merging(big) { $1 }),
                principal: .engineer(.devin))
            XCTFail("oversized checkpoint must fail")
        } catch WorkshopError.invalidRequest(_) {}
        // Secret rejected.
        var secret = checkpointBody()
        secret["next_action"] = .string("use sk-abc123def456ghi789")
        do {
            _ = try await svc.callTool("workshop_save_checkpoint", args: .object(
                ["task_id": .string(taskID.rawValue)].merging(secret) { $1 }),
                principal: .engineer(.devin))
            XCTFail("secret checkpoint must fail")
        } catch WorkshopError.invalidRequest(_) {}
    }

    func testCorruptCheckpointSkipped() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        _ = try await svc.callTool("workshop_save_checkpoint", args: .object(
            ["task_id": .string(taskID.rawValue)]
                .merging(checkpointBody()) { $1 }),
            principal: .engineer(.devin))
        // Inject a malformed newer row directly.
        try await svc.insertCorruptCheckpointForTest(taskID: taskID,
                                                     engineer: .devin)
        let cp = try await svc.loadValidCheckpoint(taskID: taskID,
                                                   engineerID: .devin)
        XCTAssertNotNil(cp)
        let events = try await systemEvents(svc, taskID)
        XCTAssertTrue(events.contains {
            $0.contains("Corrupt checkpoint skipped")
        })
    }

    // MARK: - T13/T14 capacity

    func testT13CriticalCapacityBlocksDispatch() async throws {
        let adapters = fakes()
        let policy = CapacityPolicy(dailyTokenCap: 100_000, reservePerTurn: 30_000)
        let svc = try makeService(adapters: adapters,
                                  capacityPolicies: [.devin: policy])
        let taskID = try await task(svc)
        // Push usage to 95% of cap → critical.
        try await svc.insertUsageForTest(taskID: taskID, engineer: .devin,
                                         tokens: 95_000)
        let snapshot = await svc.measureCapacity(.devin)
        XCTAssertEqual(snapshot?.availability, "critical")
        // Dispatch (turn) to devin is skipped with one system event.
        let sub = try await claim(svc, taskID: taskID, owner: .devin)
        _ = sub
        await svc.runTurnForTest(engineer: .devin, taskID: taskID)
        XCTAssertEqual(adapters[0].turnCount, 0)
        let events = try await systemEvents(svc, taskID)
        XCTAssertTrue(events.contains {
            $0.contains("Dispatch to Devin Fusion blocked: bucket critical")
        })
        // Reservations never oversubscribe.
        let held = try await svc.heldReservationTotalForTest(.devin)
        XCTAssertLessThanOrEqual(held, 5_000)
    }

    func testT14UnknownCapacityDistinct() async throws {
        let svc = try makeService(adapters: fakes(),
                                  capacityPolicies: [.devin: CapacityPolicy()])
        let snapshot = await svc.measureCapacity(.devin)
        XCTAssertEqual(snapshot?.remaining, "unknown")
        XCTAssertEqual(snapshot?.availability, "unknown")
        XCTAssertNil(snapshot?.unit) // never "unlimited", never a percentage
        let cap = await svc.toolGetCapacity()
        XCTAssertEqual(cap["devin"]?["remaining"]?.stringValue, "unknown")
        // Unknown is allowed unless require_known_capacity.
        let svc2 = try makeService(adapters: fakes(), file: "db2.sqlite",
                                   capacityPolicies: [.devin: CapacityPolicy()],
                                   requireKnownCapacity: true)
        _ = svc2
    }

    func testNilCountersMakeRemainingUnknown() async throws {
        // A nil-counter usage sample (Kimi reports none) → unknown, never a guess.
        let policy = CapacityPolicy(dailyTokenCap: 100_000)
        let svc = try makeService(adapters: fakes(),
                                  capacityPolicies: [.kimi: policy])
        let taskID = try await task(svc)
        try await svc.insertNilUsageForTest(taskID: taskID, engineer: .kimi)
        let snapshot = await svc.measureCapacity(.kimi)
        XCTAssertEqual(snapshot?.remaining, "unknown")
        XCTAssertEqual(snapshot?.availability, "unknown")
    }

    // MARK: - T23 cancellation states

    func testT23CancellationAcknowledgedAndUncertain() async throws {
        let devin = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        devin.script = { _ in [.waitForCancel] }
        let svc = try makeService(adapters: [devin]
            + EngineerID.allCases.dropFirst().map {
                FakeAdapter(engineer: $0, delayPerDelta: .zero) })
        let taskID = try await task(svc)
        _ = try await claim(svc, taskID: taskID, owner: .devin)
        try await svc.setTaskStateForTest(taskID, .working)
        // Manually start a turn so there is a running turn to cancel.
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                                 concurrent: true)
        try await Task.sleep(for: .milliseconds(100))
        try await svc.pauseTask(taskID: taskID, principal: .user)
        let events = try await systemEvents(svc, taskID)
        XCTAssertTrue(events.contains { $0.contains("turn cancellation requested") })
        XCTAssertTrue(events.contains {
            $0.contains("Turn cancellation acknowledged")
        })
        let turns = try await svc.turnsForTest(taskID)
        XCTAssertTrue(turns.contains {
            $0.state == "cancelled" || $0.state == "cancel_requested"
        })

        // No-ack path → uncertain.
        let devin2 = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        devin2.cancelAcknowledged = false
        devin2.script = { _ in [.waitForCancel] }
        let svc2 = try makeService(adapters: [devin2]
            + EngineerID.allCases.dropFirst().map {
                FakeAdapter(engineer: $0, delayPerDelta: .zero) },
            file: "db2.sqlite")
        let taskID2 = try await task(svc2)
        _ = try await claim(svc2, taskID: taskID2, owner: .devin)
        try await svc2.setTaskStateForTest(taskID2, .working)
        await svc2.runTurnForTest(engineer: .devin, taskID: taskID2,
                                  concurrent: true)
        try await Task.sleep(for: .milliseconds(100))
        try await svc2.pauseTask(taskID: taskID2, principal: .user)
        let turns2 = try await svc2.turnsForTest(taskID2)
        XCTAssertTrue(turns2.contains { $0.state == "uncertain" })
        let events2 = try await systemEvents(svc2, taskID2)
        XCTAssertTrue(events2.contains {
            $0.contains("Turn cancellation uncertain")
        })
    }

    // MARK: - T24 resource leases

    func testT24ResourceLeaseCAS() async throws {
        var now = Date()
        let svc = try makeService(adapters: fakes(), now: { now })
        let acq = try await svc.callTool("workshop_acquire_lease", args: .object([
            "resource": .string("browser"), "ttl_seconds": .number(60)]),
            principal: .engineer(.devin))
        XCTAssertEqual(acq["generation"]?.intValue, 1)
        // Second owner cannot acquire a live lease.
        do {
            _ = try await svc.callTool("workshop_acquire_lease", args: .object([
                "resource": .string("browser")]), principal: .engineer(.kimi))
            XCTFail("lease held")
        } catch WorkshopError.invalidRequest(_) {}
        // Renew + release CAS.
        _ = try await svc.callTool("workshop_renew_lease", args: .object([
            "resource": .string("browser"), "generation": .number(1)]),
            principal: .engineer(.devin))
        do {
            _ = try await svc.callTool("workshop_release_lease", args: .object([
                "resource": .string("browser"), "generation": .number(2)]),
                principal: .engineer(.devin))
            XCTFail("wrong generation")
        } catch WorkshopError.invalidRequest(_) {}
        _ = try await svc.callTool("workshop_release_lease", args: .object([
            "resource": .string("browser"), "generation": .number(1)]),
            principal: .engineer(.devin))
        // A fresh acquire after release starts at generation 1.
        let acq2 = try await svc.callTool("workshop_acquire_lease", args: .object([
            "resource": .string("browser"), "ttl_seconds": .number(60)]),
            principal: .engineer(.kimi))
        XCTAssertEqual(acq2["generation"]?.intValue, 1)
        // Expiry takeover: devin takes the expired lease at generation 2;
        // kimi's stale renew/release is refused.
        now = now.addingTimeInterval(400)
        let acq3 = try await svc.callTool("workshop_acquire_lease", args: .object([
            "resource": .string("browser")]), principal: .engineer(.devin))
        XCTAssertEqual(acq3["generation"]?.intValue, 2)
        do {
            _ = try await svc.callTool("workshop_renew_lease", args: .object([
                "resource": .string("browser"), "generation": .number(1)]),
                principal: .engineer(.kimi))
            XCTFail("stale owner renew must fail")
        } catch WorkshopError.invalidRequest(_) {}
    }

    // MARK: - T29 reconcile

    func testT29ReconcileOnStart() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        let sub = try await claim(svc, taskID: taskID, owner: .devin)
        try await svc.insertTurnForTest(taskID: taskID, subtaskID: sub.id,
                                        engineer: .devin, generation: 1)
        try await svc.insertHeldReservationForTest(taskID: taskID,
                                                   engineer: .devin)
        _ = try await svc.insertWakeupForTest(taskID: taskID, engineer: .devin,
                                              reason: "x", state: "running")
        let svc2 = try makeService(adapters: fakes())
        await svc2.reconcileOnStart()
        let turns2 = try await svc2.turnsForTest(taskID)
        XCTAssertEqual(turns2.first?.state, "interrupted")
        let held = try await svc2.reservationsForTest(state: "held")
        XCTAssertTrue(held.isEmpty)
        let wakeups = try await svc2.wakeupsForTest(taskID)
        XCTAssertTrue(wakeups.allSatisfy { $0.state != "running" })
    }

    func testWakeReconcileDeadProcess() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        let sub = try await claim(svc, taskID: taskID, owner: .devin)
        try await svc.insertTurnForTest(taskID: taskID, subtaskID: sub.id,
                                        engineer: .devin, generation: 1)
        await svc.simulateWake { _ in false } // harness dead
        let interrupted = try await svc.turnsForTest(taskID)
        XCTAssertEqual(interrupted.first?.state, "interrupted")
        // Alive process → left running.
        try await svc.insertTurnForTest(taskID: taskID, subtaskID: sub.id,
                                        engineer: .kimi, generation: 1)
        await svc.simulateWake { _ in true }
        let stillRunning = try await svc.turnsForTest(taskID, state: "running")
        XCTAssertEqual(stillRunning.count, 1)
    }

    // MARK: - T30 storage guard

    func testT30StorageGuard() async throws {
        let svc = try makeService(adapters: fakes(),
                                  freeSpaceBytes: { 50 * 1_048_576 })
        do {
            _ = try await svc.createTask(CreateTaskRequest(
                idempotencyKey: UUID().uuidString, title: "T", objective: "o",
                phase: .execution, participants: [.devin]))
            XCTFail("storage low must refuse createTask")
        } catch WorkshopError.storageLow(_) {}
        // Reads still work on a service that already has data.
        let svcOK = try makeService(adapters: fakes(), file: "ok.sqlite")
        let taskID = try await task(svcOK)
        let svcLow = try CollaborationService(
            databasePath: dir + "/ok.sqlite", adapters: fakes(),
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0,
            freeSpaceBytes: { 1024 })
        let detail = try await svcLow.getTask(taskID)
        XCTAssertNotNil(detail)
        do {
            _ = try await svcLow.callTool("workshop_save_checkpoint",
                args: .object(["task_id": .string(taskID.rawValue)]
                    .merging(checkpointBody()) { $1 }),
                principal: .engineer(.devin))
            XCTFail("checkpoint must refuse")
        } catch let error as WorkshopError {
            XCTAssertEqual(error.rpcCode, -32010)
        }
        let events = try await systemEvents(svcLow, taskID)
        XCTAssertTrue(events.contains { $0.contains("Storage critically low") })
    }

    // MARK: - T31 pagination

    func testT31MessagePaging() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        try await svc.insertMessagesForTest(taskID: taskID, count: 5_000)
        let start = Date()
        let page = try await svc.readMessagePage(taskID)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(page.count, 500)
        XCTAssertLessThan(elapsed, 0.3,
                          "newest page took \(elapsed)s")
        // Page backwards: next window ends at first seq of the previous page.
        let older = try await svc.readMessagePage(taskID,
                                                  beforeSeq: page[0].seq)
        XCTAssertEqual(older.count, 500)
        XCTAssertLessThan(older.last!.seq, page[0].seq)
        // Overlapping-free windows covering 5000 + system messages.
        let page3 = try await svc.readMessagePage(taskID,
                                                  beforeSeq: older[0].seq)
        XCTAssertEqual(page3.last!.seq, older[0].seq - 1)
    }

    // MARK: - T32 redaction

    func testT32Redaction() async throws {
        Redactor.shared.registerSecret("sk-testSECRETvalue999")
        XCTAssertTrue(Redactor.shared.containsSecret("key is sk-testSECRETvalue999"))
        XCTAssertTrue(Redactor.shared.containsSecret("api_key=abcdef123"))
        XCTAssertTrue(Redactor.shared.containsSecret("Bearer tok123"))
        let out = Redactor.shared.redact("token: sk-testSECRETvalue999 end")
        XCTAssertFalse(out.contains("sk-testSECRETvalue999"))
        // Export redacts message bodies.
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        _ = try await svc.postMessage(taskID: taskID,
                                      body: "leak sk-testSECRETvalue999",
                                      principal: .user)
        let dest = dir + "/export"
        _ = try await svc.exportTask(taskID: taskID, destDir: dest)
        let md = try String(contentsOfFile: dest + "/T.md", encoding: .utf8)
        XCTAssertFalse(md.contains("sk-testSECRETvalue999"))
        XCTAssertTrue(md.contains("***REDACTED***"))
    }

    // MARK: - T15 all providers unavailable

    func testT15AllUnavailableKeepsTaskDurable() async throws {
        let adapters = EngineerID.allCases.map {
            FakeAdapter(engineer: $0, delayPerDelta: .zero,
                        health: .unavailable("down"))
        }
        let svc = try CollaborationService(
            databasePath: dir + "/db.sqlite", adapters: adapters,
            dispatcherEnabled: true, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0)
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "o",
            phase: .execution, participants: [.devin, .kimi, .deepseek]))
        await svc.start()
        await svc.awaitIdle()
        // Task durable: persisted + blocked, one event, turns never ran.
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .blocked)
        let events = try await systemEvents(svc, receipt.taskID)
            .filter { $0.contains("No eligible engineer") }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(adapters[0].turnCount, 0)
        // Re-probe is throttled to ≤1 per engineer per 5 min: a second task
        // within the window reuses the cached probes — no retry storm.
        let probes = adapters.map { $0.probeCount }
        _ = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T2", objective: "o",
            phase: .execution, participants: [.devin, .kimi, .deepseek]))
        await svc.awaitIdle()
        XCTAssertEqual(adapters.map { $0.probeCount }, probes)
    }

    // MARK: - T38 backup

    func testT38BackupWhileWriting() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        _ = try workspaceFile(svc, taskID, "a.txt", "content")
        _ = try await svc.callTool("workshop_publish_artifact", args: .object([
            "task_id": .string(taskID.rawValue), "path": .string("a.txt"),
            "description": .string("d")]), principal: .engineer(.devin))
        // Writer active during backup.
        async let writer: () = {
            for i in 0..<20 {
                _ = try? await svc.postMessage(taskID: taskID,
                                               body: "w\(i)", principal: .user)
            }
        }()
        let dest = dir + "/backup"
        _ = try await svc.backup(destDir: dest)
        _ = await writer
        // Open the backup: schema v4, task count ≥ 1, artifact hash verifies.
        let backupDB = try Database(path: dest + "/workshop.sqlite")
        try Migrations.all.migrate(backupDB)
        let version = try backupDB.query(
            "SELECT MAX(version) AS v FROM schema_migrations")
            .first?["v"]?.int
        XCTAssertEqual(version, 7)
        let count = try backupDB.query("SELECT COUNT(*) AS c FROM tasks")
            .first?["c"]?.int ?? 0
        XCTAssertGreaterThanOrEqual(count, 1)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(
            contentsOf: URL(fileURLWithPath: dest + "/manifest.json")))
        XCTAssertEqual(manifest["schema_version"]?.intValue, 7)
        if case .object(let hashes) = manifest["artifact_hashes"] {
            XCTAssertFalse(hashes.isEmpty)
        } else {
            XCTFail("manifest missing artifact_hashes")
        }
    }

    // MARK: - Search / export / diagnostics

    func testSearchFindsMessages() async throws {
        let svc = try makeService(adapters: fakes())
        let taskID = try await task(svc)
        _ = try await svc.postMessage(taskID: taskID,
                                      body: "the needle phrase here",
                                      principal: .user)
        let hits = try await svc.search(query: "needle phrase")
        XCTAssertTrue(hits.contains { $0.taskID == taskID })
        let fts5 = await svc.sqliteHasFTS5
        XCTAssertTrue(fts5, "FTS5 expected on system SQLite")
    }

    func testDiagnosticsShape() async throws {
        let svc = try makeService(adapters: fakes())
        let diag = await svc.diagnostics()
        XCTAssertNotNil(diag["harnesses"])
        XCTAssertNotNil(diag["capacity"])
        if case .bool(let fts5) = diag["sqlite_fts5"] {
            XCTAssertTrue(fts5)
        } else {
            XCTFail("diagnostics missing sqlite_fts5")
        }
    }
}
