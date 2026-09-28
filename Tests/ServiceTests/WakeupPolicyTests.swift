import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-E1/G-E2/G-D4/G-D5: user mentions wake the mentioned participants, the
/// round limit counts only completed substantive turns, and launch/probe
/// failures re-queue wakeups with bounded backoff instead of dropping them.
final class WakeupPolicyTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-wp-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(adapters: [EngineerAdapter],
                             loopBound: Int = 6) throws -> CollaborationService {
        try CollaborationService(
            databasePath: dir + "/db-\(UUID().uuidString).sqlite",
            adapters: adapters, dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero, wakeupLoopBound: loopBound,
            wakeupRetryBackoff: [.milliseconds(50), .milliseconds(50),
                                 .milliseconds(50)],
            researchDeadline: 0, reviewDeadline: 0)
    }

    private func task(_ svc: CollaborationService,
                      participants: [EngineerID]) async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
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

    /// Post an engineer-authored "@kimi" mention and wait until its wakeup
    /// row reaches a terminal state (done or silent).
    private func mentionAndSettle(_ svc: CollaborationService, taskID: TaskID,
                                  body: String) async throws -> Bool {
        let before = try await svc.wakeupsForTest(taskID).map(\.id).max() ?? 0
        _ = try await svc.postMessage(taskID: taskID, body: body,
                                      principal: .engineer(.devin))
        return await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.id > before && ["done", "silent", "launch_failed", "failed"]
                    .contains($0.state)
            }
        }
    }

    /// A user @mention wakes exactly the mentioned participants (G-E1).
    func testUserMentionWakesMentionedParticipant() async throws {
        let adapters = fakes()
        let svc = try makeService(adapters: adapters)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi please review",
                                      principal: .user)
        let woke = await waitFor { adapters.first { $0.engineer == .kimi }!.turnCount >= 1 }
        XCTAssertTrue(woke)
        let wakeups = try await svc.wakeupsForTest(taskID)
        let kimi = wakeups.filter { $0.engineerID == .kimi }
        XCTAssertEqual(kimi.map(\.reason), ["user_mention"])
        XCTAssertTrue(wakeups.allSatisfy { $0.engineerID == .kimi },
                      "owner is not woken by an @mention of someone else")
        let ctx = adapters.first { $0.engineer == .kimi }!.receivedContexts.first
        XCTAssertEqual(ctx?.wakeReason, "user_mention")
        XCTAssertTrue(ctx?.packetText(for: .kimi)
            .contains("The user mentioned you directly") ?? false)
        await svc.shutdown()
    }

    /// user_mention bypasses the bound and resets the round counter (G-E1/E2).
    func testUserMentionResetsLoopBound() async throws {
        let adapters = fakes()
        let svc = try makeService(adapters: adapters, loopBound: 2)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        // Two substantive mention rounds reach the bound; the third is suppressed.
        let a = try await mentionAndSettle(svc, taskID: taskID, body: "@kimi a")
        XCTAssertTrue(a)
        let b = try await mentionAndSettle(svc, taskID: taskID, body: "@kimi b")
        XCTAssertTrue(b)
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi c",
                                      principal: .engineer(.devin))
        let suppressed = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.state == "suppressed" }
        }
        XCTAssertTrue(suppressed)
        // A user mention goes through anyway and resets the counter.
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi from user",
                                      principal: .user)
        let reset = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.reason == "user_mention"
                    && $0.state == "done" }
        }
        XCTAssertTrue(reset)
        // A following engineer mention is not suppressed.
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi again",
                                      principal: .engineer(.devin))
        let ranAgain = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.reason == "mention"
                    && $0.state == "done" }
        }
        XCTAssertTrue(ranAgain)
        await svc.shutdown()
    }

    /// Failed launches do not count toward the round limit; only completed
    /// substantive turns do (G-E2 + G-D4).
    func testFailedLaunchesDoNotCountAsRounds() async throws {
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        kimi.openSessionError = WorkshopError.adapterUnavailable(.kimi)
        let svc = try makeService(adapters: fakes().map {
            $0.engineer == .kimi ? kimi : $0 })
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        // Six mention wakeups, every turn fails to start → launch_failed
        // after three attempts each, and no round-limit event.
        for i in 0..<6 {
            let settled = try await mentionAndSettle(
                svc, taskID: taskID, body: "@kimi fail\(i)")
            XCTAssertTrue(settled)
        }
        let rows = try await svc.wakeupsForTest(taskID)
            .filter { $0.reason == "mention" }
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { $0.state == "launch_failed" })
        let earlyMessages = try await svc.readMessages(taskID)
        XCTAssertFalse(earlyMessages.contains {
            $0.body == "Discussion round limit reached; waiting for user" })

        // Six substantive rounds after the adapter recovers → bound fires.
        kimi.openSessionError = nil
        for i in 0..<6 {
            let settled = try await mentionAndSettle(
                svc, taskID: taskID, body: "@kimi ok\(i)")
            XCTAssertTrue(settled)
        }
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi over",
                                      principal: .engineer(.devin))
        let limited = await waitFor {
            try await svc.readMessages(taskID).contains {
                $0.body == "Discussion round limit reached; waiting for user" }
        }
        XCTAssertTrue(limited)
        await svc.shutdown()
    }

    /// A turn that produces nothing is silent: not a round, one event (G-E2).
    func testSilentTurnDoesNotCountAsRound() async throws {
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        kimi.script = { _ in [] }
        let svc = try makeService(adapters: fakes().map {
            $0.engineer == .kimi ? kimi : $0 }, loopBound: 2)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        for i in 0..<3 {
            let settled = try await mentionAndSettle(
                svc, taskID: taskID, body: "@kimi silent\(i)")
            XCTAssertTrue(settled)
        }
        let rows = try await svc.wakeupsForTest(taskID)
            .filter { $0.reason == "mention" }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.state == "silent" })
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent && $0.body.contains("(silent)") })
        // Silent turns never fill the round counter.
        XCTAssertFalse(messages.contains {
            $0.body == "Discussion round limit reached; waiting for user" })
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi still fine",
                                      principal: .engineer(.devin))
        let notSuppressed = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.reason == "mention" && $0.state == "silent"
                    && $0.id > rows.last!.id }
        }
        XCTAssertTrue(notSuppressed)
        await svc.shutdown()
    }

    /// Launch failures re-queue with backoff and recover mid-flight (G-D4).
    func testLaunchBackoffRetriesThenSucceeds() async throws {
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        kimi.openSessionError = WorkshopError.adapterUnavailable(.kimi)
        // A longer second step leaves room to clear the failure between the
        // second and third attempts.
        let svc = try CollaborationService(
            databasePath: dir + "/db-\(UUID().uuidString).sqlite",
            adapters: fakes().map { $0.engineer == .kimi ? kimi : $0 },
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero,
            wakeupRetryBackoff: [.milliseconds(50), .milliseconds(600),
                                 .milliseconds(50)],
            researchDeadline: 0, reviewDeadline: 0)
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi wake up",
                                      principal: .engineer(.devin))
        let two = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.attempt == 2 }
        }
        XCTAssertTrue(two)
        let events = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent && $0.body.contains("retry ") }
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].body.contains("retry 1/3"))
        XCTAssertTrue(events[1].body.contains("retry 2/3"))
        XCTAssertTrue(events[0].body.contains("Turn could not start for Kimi"))
        kimi.openSessionError = nil
        let recovered = await waitFor {
            guard kimi.turnCount >= 1 else { return false }
            let rows = ((try? await svc.wakeupsForTest(taskID)) ?? [])
                .filter { $0.engineerID == .kimi }
            return !rows.isEmpty && rows.allSatisfy { $0.state == "done" } }
        XCTAssertTrue(recovered)
        await svc.shutdown()
    }

    /// After the schedule is exhausted the rows are launch_failed and no
    /// further events are posted (G-D4).
    func testLaunchFailureExhaustsAfterThreeAttempts() async throws {
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero)
        kimi.openSessionError = WorkshopError.adapterUnavailable(.kimi)
        let svc = try makeService(adapters: fakes().map {
            $0.engineer == .kimi ? kimi : $0 })
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi wake up",
                                      principal: .engineer(.devin))
        let exhausted = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.state == "launch_failed" }
        }
        XCTAssertTrue(exhausted)
        var events = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent }
        XCTAssertEqual(events.filter { $0.body.contains("; retry ") }.count, 3)
        XCTAssertEqual(events.filter {
            $0.body.contains("Could not start Kimi") }.count, 1)
        let eventCount = events.count
        // No further retries or events after the backoff schedule.
        try? await Task.sleep(for: .milliseconds(250))
        events = try await svc.readMessages(taskID).filter {
            $0.kind == .systemEvent }
        XCTAssertEqual(events.count, eventCount)
        await svc.shutdown()
    }

    /// An unavailable probe defers the wakeup ("Waiting for …") instead of
    /// dropping it; the probe is advisory (G-D5).
    func testUnavailableProbeDefersWakeup() async throws {
        let kimi = FakeAdapter(engineer: .kimi, delayPerDelta: .zero,
                               health: .unavailable("version probe failed"))
        let svc = try makeService(adapters: fakes().map {
            $0.engineer == .kimi ? kimi : $0 })
        let taskID = try await task(svc, participants: [.devin, .kimi])
        await svc.start()
        _ = try await svc.postMessage(taskID: taskID, body: "@kimi ping",
                                      principal: .engineer(.devin))
        let deferred = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.attempt == 1
                    && $0.state == "pending" && $0.notBefore != nil }
        }
        XCTAssertTrue(deferred)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent
                && $0.body.contains("Waiting for Kimi") })
        let anySuppressed = try await svc.wakeupsForTest(taskID).contains {
            $0.engineerID == .kimi && $0.state == "suppressed" }
        XCTAssertFalse(anySuppressed)
        // The advisory probe keeps deferring until the schedule exhausts.
        let exhausted = await waitFor {
            try await svc.wakeupsForTest(taskID).contains {
                $0.engineerID == .kimi && $0.state == "launch_failed" }
        }
        XCTAssertTrue(exhausted)
        await svc.shutdown()
    }
}
