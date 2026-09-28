import XCTest
@testable import WorkshopService
@testable import WorkshopCore

/// G-E5: authoritative v2 turns are gated on `config/capabilities.json`
/// records, injected into the adapter's `capabilityLookup` exactly as
/// DaemonRuntime does. FakeAdapter consults the lookup when one is set.
final class CapabilityGateTests: XCTestCase {
    var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "/capgate-" + UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func task(_ svc: CollaborationService) async throws -> TaskID {
        try await svc.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: UUID().uuidString, title: "T",
            objective: "obj", phase: .execution, participants: [.devin],
            collaborationMode: .ownerOnly), principal: .user).taskID
    }

    /// No record → the dispatched authoritative turn is blocked; once a
    /// qualified record exists, the next task's turn runs (the daemon-side
    /// lookup is all that changed).
    func testAuthoritativeTurnGatedByCapabilityRecord() async throws {
        let store = CapabilityStore(path: dir + "/capabilities.json")
        let fake = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        fake.capabilityLookup = { store.record(for: $0) }
        let svc = try CollaborationService(
            databasePath: dir + "/db.sqlite",
            adapters: [fake, FakeAdapter(engineer: .kimi),
                       FakeAdapter(engineer: .deepseek)],
            dispatcherEnabled: true, homeDir: dir)
        await svc.start()
        let taskID = try await task(svc)

        // Dispatch must hit the gate and block the task instead of running.
        let deadline = Date().addingTimeInterval(5)
        var detail = try await svc.getTask(taskID)
        while detail.task.state != .blocked, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            detail = try await svc.getTask(taskID)
        }
        XCTAssertEqual(detail.task.state, .blocked)
        XCTAssertEqual(fake.turnCount, 0)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.body.contains("writer isolation is not qualified") })

        // With a qualified record the same engineer runs its next turn.
        try store.record(CapabilityRecord(
            engineer: .devin, lane: "native",
            capability: CapabilityStore.isolatedWriter,
            model: "fake-model", qualified: true, probedAt: Date()))
        _ = try await task(svc)
        let runDeadline = Date().addingTimeInterval(5)
        while fake.turnCount == 0, Date() < runDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(fake.turnCount, 1)
        await svc.shutdown()
    }

    /// Records match exactly on (engineer, lane, capability, model); a
    /// qualified record for another lane or model does not qualify.
    func testRecordMatchRequiresExactIdentity() throws {
        let store = CapabilityStore(path: dir + "/capabilities.json")
        let identity = QualificationIdentity(engineer: .devin, lane: "native",
                                             model: "m1")
        XCTAssertNil(store.isQualified(identity))
        try store.record(CapabilityRecord(
            engineer: .devin, lane: "managed", capability: "isolated_writer",
            model: "m1", qualified: true, probedAt: Date()))
        try store.record(CapabilityRecord(
            engineer: .devin, lane: "native", capability: "isolated_writer",
            model: "other", qualified: true, probedAt: Date()))
        XCTAssertNil(store.isQualified(identity))
        try store.record(CapabilityRecord(
            engineer: .devin, lane: "native", capability: "isolated_writer",
            model: "m1", qualified: true, probedAt: Date()))
        XCTAssertEqual(store.isQualified(identity)?.qualified, true)
        // Upsert replaces the same key; a failed re-qualification retracts it.
        try store.record(CapabilityRecord(
            engineer: .devin, lane: "native", capability: "isolated_writer",
            model: "m1", qualified: false, probedAt: Date(),
            notes: "recipe timed out"))
        XCTAssertNil(store.isQualified(identity))
        XCTAssertEqual(store.load().count, 3)
    }

    /// Store writes mode 0600 atomically and tolerates a missing file.
    func testStoreFileModeAndMissingFile() throws {
        let path = dir + "/sub/capabilities.json"
        let store = CapabilityStore(path: path)
        XCTAssertEqual(store.load(), [])
        try store.record(CapabilityRecord(
            engineer: .kimi, lane: "managed", capability: "isolated_writer",
            qualified: true, probedAt: Date()))
        let mode = try FileManager.default
            .attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let reloaded = CapabilityStore(path: path)
        XCTAssertEqual(reloaded.load().count, 1)
    }

    /// The store writes ISO-8601 probedAt but still decodes files written by
    /// the pre-ISO encoder (raw seconds-since-2001 doubles) — a mixed-fleet
    /// requirement while older daemons remain installed.
    func testProbedAtCodecReadsNumericAndISO() throws {
        let path = dir + "/capabilities.json"
        let base: [String: Any] = [
            "engineer": "devin", "lane": "native",
            "capability": "isolated_writer", "qualified": true,
            "evidencePath": "ev"]
        let isoText = "2026-09-28T05:38:08.029Z"
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(f.date(from: isoText))
        var numeric = base
        numeric["probedAt"] = expected.timeIntervalSinceReferenceDate
        var iso = base; iso["probedAt"] = isoText
        try JSONSerialization.data(withJSONObject: [numeric])
            .write(to: URL(fileURLWithPath: path))
        var loaded = CapabilityStore(path: path).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].probedAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 0.01)
        try JSONSerialization.data(withJSONObject: [iso])
            .write(to: URL(fileURLWithPath: path))
        loaded = CapabilityStore(path: path).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].probedAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 0.01)
        // Writes are ISO.
        let store = CapabilityStore(path: path)
        try store.record(CapabilityRecord(
            engineer: .kimi, lane: "native", capability: "isolated_writer",
            qualified: true, probedAt: Date()))
        let text = try String(contentsOfFile: path)
        XCTAssertTrue(text.contains("\"probedAt\":\"20"))
    }
}
