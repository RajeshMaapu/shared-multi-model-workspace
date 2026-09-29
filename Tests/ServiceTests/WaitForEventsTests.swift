import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// G-A3/G-A4: bounded wait_for_events long-poll, the Codex acknowledged
/// cursor, and idempotent message append.
final class WaitForEventsTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-wfe-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(_ name: String = "wfe") throws -> CollaborationService {
        let svc = try CollaborationService(
            databasePath: dir + "/\(name).sqlite", adapters: fakes(),
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .seconds(3600),
            wakeupRetryBackoff: [.seconds(60)],
            researchDeadline: 0, reviewDeadline: 0)
        return svc
    }

    private func task(_ svc: CollaborationService,
                      participants: [EngineerID] = [.devin],
                      principal: Principal = .user) async throws -> TaskID {
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "obj",
            phase: .execution, participants: participants),
            principal: principal)
        return receipt.taskID
    }

    private func field(_ json: JSONValue, _ key: String) -> JSONValue? {
        json[key]
    }

    /// a. Existing events return immediately; turn_summary rows are excluded.
    func testWaitForEventsReturnsImmediately() async throws {
        let svc = try makeService("a")
        let taskID = try await task(svc)
        try await svc.postMessage(taskID: taskID, body: "one")
        let second = try await svc.postMessage(taskID: taskID, body: "two")
        let result = try await svc.waitForEvents(taskID: taskID, afterSeq: 1,
                                                 principal: .user)
        XCTAssertEqual(result["events"]?.arrayValue?.count, 2)
        XCTAssertEqual(result["last_seq"]?.intValue, 3)
        XCTAssertEqual(result["timed_out"], .bool(false))
        XCTAssertEqual(result["task_state"]?.stringValue, "queued")

        // A turn_summary row never surfaces as an event.
        let db = try Database(path: dir + "/a.sqlite")
        try db.execute("UPDATE messages SET kind='turn_summary' WHERE id=?",
                       [.text(second.id.rawValue)])
        let again = try await svc.waitForEvents(taskID: taskID, afterSeq: 1,
                                                timeoutSeconds: 1,
                                                principal: .user)
        XCTAssertEqual(again["events"]?.arrayValue?.count, 1)
        XCTAssertEqual(again["events"]?.arrayValue?.first?["body"]?.stringValue, "one")
        XCTAssertEqual(again["last_seq"]?.intValue, 2)
    }

    /// b. A waiter parks and is resumed by the next committed message.
    func testWaitForEventsWakesOnPost() async throws {
        let svc = try makeService("b")
        let taskID = try await task(svc)
        let polled = Task {
            try await svc.waitForEvents(taskID: taskID, afterSeq: 1,
                                        timeoutSeconds: 5, principal: .user)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await svc.postMessage(taskID: taskID, body: "late event")
        let started = Date()
        let result = try await polled.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result["timed_out"], .bool(false))
        let events = result["events"]?.arrayValue ?? []
        XCTAssertTrue(events.contains { $0["body"]?.stringValue == "late event" })
        let count = await svc.waiterCount
        XCTAssertEqual(count, 0)
    }

    /// c. Deadline expiry returns timed_out and leaves no waiter behind.
    func testWaitForEventsTimeout() async throws {
        let svc = try makeService("c")
        let taskID = try await task(svc)
        let result = try await svc.waitForEvents(taskID: taskID, afterSeq: 1,
                                                 timeoutSeconds: 1,
                                                 principal: .user)
        XCTAssertEqual(result["events"]?.arrayValue?.count, 0)
        XCTAssertEqual(result["timed_out"], .bool(true))
        XCTAssertEqual(result["last_seq"]?.intValue, 1)
        let count = await svc.waiterCount
        XCTAssertEqual(count, 0)
    }

    /// c2. after_seq is a task-message cursor: an out-of-range value (e.g. a
    /// receipt committed_seq) is rejected as -32602 naming both numbers.
    func testOverRangeAfterSeqRejected() async throws {
        let svc = try makeService("c2")
        let taskID = try await task(svc)
        let latest = try svc.repoForTests.maxCommittedMessageSeq(taskID)
        await XCTAssertThrowsErrorAsync(
            try await svc.waitForEvents(taskID: taskID, afterSeq: 5000,
                                        timeoutSeconds: 1,
                                        principal: .user)) { error in
            guard case WorkshopError.invalidRequest(let why) = error else {
                return XCTFail("expected invalidRequest, got \(error)")
            }
            XCTAssertEqual((error as? WorkshopError)?.rpcCode, -32602)
            XCTAssertTrue(why.contains("after_seq 5000"), why)
            XCTAssertTrue(why.contains("seq \(latest)"), why)
            XCTAssertTrue(why.contains("committed_seq"), why)
        }
        await XCTAssertThrowsErrorAsync(
            try await svc.toolReadMessages(taskID: taskID, afterSeq: 5000, limit: 50,
                                     principal: .codex)) { error in
            XCTAssertEqual((error as? WorkshopError)?.rpcCode, -32602)
        }
    }

    /// c3. An inflated stored acknowledgement (a receipt committed_seq) is
    /// repaired to the task's latest message seq on the next read.
    func testInflatedAckRepairedOnRead() async throws {
        let svc = try makeService("c3")
        let taskID = try await task(svc, participants: [.devin, .kimi],
                                    principal: .codex)
        try await svc.postMessage(taskID: taskID, body: "m")
        let maxSeq = try svc.repoForTests.maxCommittedMessageSeq(taskID)
        try svc.repoForTests.db.execute(
            "UPDATE task_ingress SET last_acknowledged_seq=44598 WHERE task_id=?",
            [.text(taskID.rawValue)])
        _ = try await svc.waitForEvents(taskID: taskID, afterSeq: 0,
                                        timeoutSeconds: 1, principal: .codex)
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.acknowledgedSeq, maxSeq)
    }

    /// c4. Daemon startup repairs every inflated acknowledgement row.
    func testStartupRepairsInflatedAck() async throws {
        let svc = try makeService("c4")
        let taskID = try await task(svc, participants: [.devin, .kimi],
                                    principal: .codex)
        try await svc.postMessage(taskID: taskID, body: "m")
        let maxSeq = try svc.repoForTests.maxCommittedMessageSeq(taskID)
        try svc.repoForTests.db.execute(
            "UPDATE task_ingress SET last_acknowledged_seq=44598 WHERE task_id=?",
            [.text(taskID.rawValue)])
        await svc.start()
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.acknowledgedSeq, maxSeq)
    }

    /// d. Codex reads advance task_ingress.last_acknowledged_seq.
    func testCodexAcknowledgedCursor() async throws {
        let svc = try makeService("d")
        let taskID = try await task(svc, participants: [.devin, .kimi],
                                    principal: .codex)
        try await svc.postMessage(taskID: taskID, body: "first")
        let result = try await svc.waitForEvents(taskID: taskID, afterSeq: 0,
                                                 timeoutSeconds: 1,
                                                 principal: .codex)
        let lastSeq = try XCTUnwrap(result["last_seq"]?.intValue)
        XCTAssertEqual(lastSeq, 2)
        var detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.acknowledgedSeq, Int64(lastSeq))

        // toolReadMessages as codex advances further.
        try await svc.postMessage(taskID: taskID, body: "second")
        _ = try await svc.toolReadMessages(taskID: taskID, afterSeq: 0, limit: 50,
                                           principal: .codex)
        detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.acknowledgedSeq, 3)

        // An engineer read does not move the Codex cursor.
        _ = try await svc.toolReadMessages(taskID: taskID, afterSeq: 0, limit: 50,
                                           principal: .engineer(.devin))
        detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.acknowledgedSeq, 3)
    }

    /// e. The 33rd concurrent waiter for a principal kind is refused.
    func testWaiterCap() async throws {
        let svc = try makeService("e")
        let taskID = try await task(svc)
        var waiters: [Task<JSONValue, Error>] = []
        for _ in 0..<32 {
            waiters.append(Task {
                try await svc.waitForEvents(taskID: taskID, afterSeq: 1,
                                            timeoutSeconds: 10,
                                            principal: .codex)
            })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await XCTAssertThrowsErrorAsync(
            try await svc.waitForEvents(taskID: taskID, afterSeq: 1,
                                        timeoutSeconds: 1, principal: .codex)) { error in
            XCTAssertEqual((error as? WorkshopError)?.rpcCode,
                           WorkshopProtocol.ErrorCode.tooManyWaiters)
        }
        // Wake the parked waiters so the test finishes promptly.
        try await svc.postMessage(taskID: taskID, body: "release")
        for waiter in waiters {
            _ = try await waiter.value
        }
        let count = await svc.waiterCount
        XCTAssertEqual(count, 0)
    }

    /// f. idempotency_key dedupes per principal; conflicts are -32009.
    func testIdempotentAppend() async throws {
        let svc = try makeService("f")
        let taskID = try await task(svc, participants: [.devin, .kimi],
                                    principal: .codex)

        let first = try await svc.toolPostMessage(
            taskID: taskID, body: "same body", kind: "text", replyTo: nil,
            idempotencyKey: "k1", principal: .codex)
        let second = try await svc.toolPostMessage(
            taskID: taskID, body: "same body", kind: "text", replyTo: nil,
            idempotencyKey: "k1", principal: .codex)
        XCTAssertEqual(first.id, second.id)

        await XCTAssertThrowsErrorAsync(
            try await svc.toolPostMessage(
                taskID: taskID, body: "different body", kind: "text",
                replyTo: nil, idempotencyKey: "k1", principal: .codex)) { error in
            XCTAssertEqual(error as? WorkshopError, .idempotencyConflict)
            XCTAssertEqual((error as? WorkshopError)?.rpcCode, -32009)
        }

        // Without a key every call commits a new message.
        _ = try await svc.toolPostMessage(taskID: taskID, body: "plain",
                                          kind: "text", replyTo: nil,
                                          principal: .codex)
        _ = try await svc.toolPostMessage(taskID: taskID, body: "plain",
                                          kind: "text", replyTo: nil,
                                          principal: .codex)
        let bodies = try await svc.readMessages(taskID).map(\.body)
        XCTAssertEqual(bodies.filter { $0 == "plain" }.count, 2)
        XCTAssertEqual(bodies.filter { $0 == "same body" }.count, 1)

        // The same key under a different principal does not collide.
        let devinPost = try await svc.toolPostMessage(
            taskID: taskID, body: "devin body", kind: "text", replyTo: nil,
            idempotencyKey: "k1", principal: .engineer(.devin))
        XCTAssertNotEqual(devinPost.id, first.id)
    }

    /// g. A retried request_review commits one message and one wakeup.
    func testRequestReviewIdempotent() async throws {
        let svc = try makeService("g")
        let taskID = try await task(svc, participants: [.devin, .kimi])
        let first = try await svc.toolRequestReview(
            taskID: taskID, reviewer: .kimi, message: "please look",
            idempotencyKey: "rr-1", principal: .engineer(.devin))
        let second = try await svc.toolRequestReview(
            taskID: taskID, reviewer: .kimi, message: "please look",
            idempotencyKey: "rr-1", principal: .engineer(.devin))
        XCTAssertEqual(first.id, second.id)
        let reviews = try await svc.readMessages(taskID)
            .filter { $0.kind == .review }
        XCTAssertEqual(reviews.count, 1)
        // The @kimi prefix makes the wakeup reason "mention"; the assertion
        // is that exactly ONE wakeup row exists for the reviewer.
        let kimiWakeups = try await svc.wakeupsForTest(taskID)
            .filter { $0.engineerID == .kimi }
        XCTAssertEqual(kimiWakeups.count, 1)
    }
}

/// Async throwing assertion helper.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected error" + (message.isEmpty ? "" : ": \(message)"),
                file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
