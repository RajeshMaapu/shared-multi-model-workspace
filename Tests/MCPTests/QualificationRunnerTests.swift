import XCTest
@testable import WorkshopDaemonKit
@testable import WorkshopService
@testable import WorkshopCore

private final class LockedBox<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()
    init(_ v: Value) { _value = v }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// G-E5: `workshop-daemon qualify` drives the hello.txt recipe against a
/// temporary home and writes config/capabilities.json. Tested with fake
/// adapters — no live inference.
final class QualificationRunnerTests: XCTestCase {
    var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "/qualify-" + UUID().uuidString.lowercased()
        let config = dir! + "/config"
        try? FileManager.default.createDirectory(atPath: config,
                                                 withIntermediateDirectories: true)
        let json = """
            {"schema_version":1,"engineers":[
              {"id":"devin"},{"id":"kimi"},{"id":"deepseek"}],
             "mcp_bridge":".build/debug/workshop-mcp"}
            """
        try? json.write(toFile: config + "/engineers.json",
                        atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if ProcessInfo.processInfo.environment["QUALIFY_KEEP"] != nil {
            print("KEEP", dir!)
            return
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    private var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["WORKSHOP_HOME"] = dir
        e["WORKSHOP_RUNTIME_DIR"] = dir + "/runtime"
        return e
    }

    /// A fake peer lane that owns the root subtask, writes the recipe file
    /// and reports a result reaches `verifying` with a SEALED writer
    /// generation → capabilities.json gains a qualified record.
    func testQualifyWritesQualifiedRecord() async throws {
        var options = QualificationRunner.Options()
        options.engineer = .kimi
        options.lane = "native"
        options.home = dir
        options.timeoutSeconds = 60
        options.evidenceDir = dir + "/evidence-pass"
        let recordBeforeShutdown = LockedBox(false)
        let sealedBeforeShutdown = LockedBox(false)
        let capabilityFile = dir + "/config/capabilities.json"
        let code = await QualificationRunner.run(options, env: env,
            fakeConfigurator: { fake in
                if fake.engineer == .kimi {
                    fake.workspaceWrites = [
                        QualificationRunner.expectedFileName:
                            QualificationRunner.expectedFileContent]
                    fake.script = { context in
                        guard let sub = context.subtask else {
                            return [.text("recipe done")]
                        }
                        return [
                            .toolCall("workshop_report_result", .object([
                                "task_id": .string(context.task.id.rawValue),
                                "subtask_id": .string(sub.id.rawValue),
                                "summary": .string("phase2 smoke ok"),
                                "generation": .number(Double(sub.generation))])),
                            .text("recipe done")]
                    }
                }
            },
            afterRecord: {
                // Runs after the verdict/record write, before shutdown —
                // the capabilities file and the sealed generation must
                // already exist.
                recordBeforeShutdown.value = FileManager.default.fileExists(
                    atPath: capabilityFile)
                if let paths = try? FileManager.default.contentsOfDirectory(
                    atPath: "/tmp") {
                    for name in paths where name.hasPrefix("wq-") {
                        let db = "/tmp/\(name)/db/workshop.sqlite"
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                        proc.arguments = [db,
                            "SELECT state FROM writer_generations "
                            + "WHERE engineer='kimi' ORDER BY rowid DESC LIMIT 1"]
                        let pipe = Pipe()
                        proc.standardOutput = pipe
                        try? proc.run()
                        proc.waitUntilExit()
                        let out = String(decoding: pipe.fileHandleForReading
                            .readDataToEndOfFile(), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if out == "sealed" { sealedBeforeShutdown.value = true }
                    }
                }
            })
        XCTAssertEqual(code, 0)
        XCTAssertTrue(recordBeforeShutdown.value)
        XCTAssertTrue(sealedBeforeShutdown.value)
        let store = CapabilityStore(path: dir + "/config/capabilities.json")
        let record = store.isQualified(QualificationIdentity(
            engineer: .kimi, lane: "native", model: "fake-model"))
        XCTAssertEqual(record?.qualified, true)
        XCTAssertEqual(record?.evidencePath, dir + "/evidence-pass")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir + "/evidence-pass/notes.txt"))
    }

    /// A fake that stalls mid-turn never seals a generation → the record is
    /// written unqualified with notes, exit 1.
    func testQualifyRecordsFailure() async throws {
        var options = QualificationRunner.Options()
        options.engineer = .kimi
        options.lane = "native"
        options.home = dir
        options.timeoutSeconds = 4
        options.evidenceDir = dir + "/evidence-fail"
        let code = await QualificationRunner.run(options, env: env) { fake in
            if fake.engineer == .kimi {
                fake.script = { _ in [.waitForCancel] }
            }
        }
        XCTAssertEqual(code, 1)
        let store = CapabilityStore(path: dir + "/config/capabilities.json")
        let record = store.record(for: QualificationIdentity(
            engineer: .kimi, lane: "native", model: "fake-model"))
        XCTAssertEqual(record?.qualified, false)
        XCTAssertFalse(record?.notes?.isEmpty ?? true)
    }

    /// CLI argument parsing.
    func testParseArguments() {
        var parsed = QualificationRunner.parse(
            ["workshop-daemon", "qualify", "--engineer", "kimi",
             "--lane", "managed", "--home", "/tmp/h",
             "--evidence-dir", "/tmp/e"])
        XCTAssertEqual(parsed?.engineer, .kimi)
        XCTAssertEqual(parsed?.lane, "managed")
        XCTAssertEqual(parsed?.home, "/tmp/h")
        XCTAssertEqual(parsed?.evidenceDir, "/tmp/e")
        parsed = QualificationRunner.parse(
            ["workshop-daemon", "qualify", "--engineer", "devin"])
        XCTAssertEqual(parsed?.lane, "native")
        XCTAssertNil(QualificationRunner.parse(
            ["workshop-daemon", "qualify"]))
        XCTAssertNil(QualificationRunner.parse(
            ["workshop-daemon", "qualify", "--engineer", "nobody"]))
        XCTAssertNil(QualificationRunner.parse(
            ["workshop-daemon", "qualify", "--engineer", "kimi",
             "--lane", "sideways"]))
    }

    /// probedAt encodes ISO-8601 and round-trips.
    func testCapabilityRecordISODate() throws {
        let record = CapabilityRecord(engineer: .kimi, lane: "native",
                                      capability: "isolated_writer",
                                      qualified: true, probedAt: Date())
        let data = try JSONEncoder().encode(record)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"probedAt\":\"20"),
                      "probedAt must be an ISO-8601 string, got \(raw)")
        let decoded = try JSONDecoder().decode(CapabilityRecord.self,
                                               from: data)
        XCTAssertEqual(decoded.engineer, .kimi)
        XCTAssertEqual(decoded.qualified, true)
        XCTAssertEqual(decoded.probedAt.timeIntervalSince1970,
                       record.probedAt.timeIntervalSince1970,
                       accuracy: 1)
    }

    /// Legacy capability files written with a raw Double probedAt
    /// (seconds since reference date) still decode.
    func testCapabilityRecordLegacyNumericDate() throws {
        let json = """
            [{"engineer":"devin","lane":"native","capability":"isolated_writer",
              "model":"m","qualified":true,"probedAt":812266288.669,
              "evidencePath":"/tmp/e"}]
            """
        let records = try JSONDecoder().decode([CapabilityRecord].self,
                                               from: Data(json.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].qualified, true)
        XCTAssertGreaterThan(records[0].probedAt.timeIntervalSince1970,
                             1_700_000_000) // ~2026, not 1970+812266288
        // ...and it round-trips through the store to ISO on rewrite.
        let store = CapabilityStore(path: dir + "/config/capabilities.json")
        try store.record(records[0])
        let raw = try String(contentsOfFile:
            dir + "/config/capabilities.json")
        XCTAssertTrue(raw.contains("\"probedAt\":\"20"))
    }

    /// --continuity-check: after a qualified recipe, the runner posts the
    /// memory question as the user; the engineer's reply is recorded on
    /// the capability record as `continuity: pass — <reply>`.
    func testContinuityCheckRecordsReply() async throws {
        var options = QualificationRunner.Options()
        options.engineer = .kimi
        options.lane = "native"
        options.home = dir
        options.timeoutSeconds = 60
        options.evidenceDir = dir + "/evidence-continuity"
        options.continuityCheck = true
        let turns = LockedBox(0)
        let code = await QualificationRunner.run(options, env: env,
            fakeConfigurator: { fake in
                if fake.engineer == .kimi {
                    fake.workspaceWrites = [
                        QualificationRunner.expectedFileName:
                            QualificationRunner.expectedFileContent]
                    fake.script = { context in
                        turns.value += 1
                        if context.subtask?.state == .review {
                            // Report already submitted — this is the
                            // continuity turn answering the memory
                            // question.
                            return [.toolCall("workshop_post_message",
                                .object([
                                    "task_id": .string(
                                        context.task.id.rawValue),
                                    "body": .string(
                                        "I created hello.txt and "
                                        + "committed it at revision 1")]))]
                        }
                        guard let sub = context.subtask else {
                            return [.text("recipe done")]
                        }
                        return [
                            .toolCall("workshop_report_result", .object([
                                "task_id": .string(context.task.id.rawValue),
                                "subtask_id": .string(sub.id.rawValue),
                                "summary": .string("phase2 smoke ok"),
                                "generation": .number(
                                    Double(sub.generation))])),
                            .text("recipe done")]
                    }
                }
            })
        XCTAssertEqual(code, 0)
        XCTAssertGreaterThanOrEqual(turns.value, 2,
            "the continuity turn must run after the recipe")
        let store = CapabilityStore(path: dir + "/config/capabilities.json")
        let record = store.record(for: QualificationIdentity(
            engineer: .kimi, lane: "native", model: "fake-model"))
        XCTAssertEqual(record?.qualified, true)
        XCTAssertTrue(record?.notes?.contains("continuity: pass") ?? false,
                      record?.notes ?? "no notes")
        XCTAssertTrue(record?.notes?.contains("hello.txt") ?? false)
    }

    /// Regression (3.6 kimi run): the continuity turn's streaming reply
    /// placeholder is a `text` row with a provisional seq that sorts LAST
    /// while the turn is still running — a poll that accepts any engineer
    /// `text` row returns its empty body and fails the check. The reply
    /// must come from a committed, non-empty message (here posted via
    /// workshop_post_message while the turn stalls in flight).
    func testContinuityCheckIgnoresStreamingPlaceholder() async throws {
        var options = QualificationRunner.Options()
        options.engineer = .kimi
        options.lane = "native"
        options.home = dir
        options.timeoutSeconds = 60
        options.evidenceDir = dir + "/evidence-continuity-stall"
        options.continuityCheck = true
        let code = await QualificationRunner.run(options, env: env,
            fakeConfigurator: { fake in
                if fake.engineer == .kimi {
                    fake.workspaceWrites = [
                        QualificationRunner.expectedFileName:
                            QualificationRunner.expectedFileContent]
                    fake.script = { context in
                        if context.subtask?.state == .review {
                            // Every review-state turn (the post-seal
                            // mention wakeup and the continuity turn)
                            // streams for a while before posting — the
                            // in-flight placeholder must be ignored both
                            // in the reply scan AND in the baseline seq
                            // (provisional seqs ≥ 1e9 would otherwise
                            // poison `afterSeq` forever).
                            return [
                                .sleep(milliseconds: 4000),
                                .toolCall("workshop_post_message", .object([
                                    "task_id": .string(
                                        context.task.id.rawValue),
                                    "body": .string(
                                        "I created hello.txt and "
                                        + "committed it at revision 1")]))]
                        }
                        guard let sub = context.subtask else {
                            return [.text("recipe done")]
                        }
                        return [
                            .toolCall("workshop_report_result", .object([
                                "task_id": .string(context.task.id.rawValue),
                                "subtask_id": .string(sub.id.rawValue),
                                "summary": .string("phase2 smoke ok"),
                                "generation": .number(
                                    Double(sub.generation))])),
                            .text("recipe done")]
                    }
                }
            })
        XCTAssertEqual(code, 0)
        let store = CapabilityStore(path: dir + "/config/capabilities.json")
        let record = store.record(for: QualificationIdentity(
            engineer: .kimi, lane: "native", model: "fake-model"))
        XCTAssertTrue(record?.notes?.contains("continuity: pass") ?? false,
                      record?.notes ?? "no notes")
        XCTAssertTrue(record?.notes?.contains("hello.txt") ?? false)
    }

    /// The continuity predicate accepts any revision number — a turn that
    /// reported twice (revision 2) still proves session continuity.
    func testContinuityCheckAcceptsLaterRevision() async throws {
        var options = QualificationRunner.Options()
        options.engineer = .kimi
        options.lane = "native"
        options.home = dir
        options.timeoutSeconds = 60
        options.evidenceDir = dir + "/evidence-continuity-rev2"
        options.continuityCheck = true
        let code = await QualificationRunner.run(options, env: env,
            fakeConfigurator: { fake in
                if fake.engineer == .kimi {
                    fake.workspaceWrites = [
                        QualificationRunner.expectedFileName:
                            QualificationRunner.expectedFileContent]
                    fake.script = { context in
                        if context.subtask?.state == .review {
                            return [.toolCall("workshop_post_message",
                                .object([
                                    "task_id": .string(
                                        context.task.id.rawValue),
                                    "body": .string(
                                        "I created hello.txt; my latest "
                                        + "result revision is revision 2")]))]
                        }
                        guard let sub = context.subtask else {
                            return [.text("recipe done")]
                        }
                        return [
                            .toolCall("workshop_report_result", .object([
                                "task_id": .string(context.task.id.rawValue),
                                "subtask_id": .string(sub.id.rawValue),
                                "summary": .string("phase2 smoke ok"),
                                "generation": .number(
                                    Double(sub.generation))])),
                            .text("recipe done")]
                    }
                }
            })
        XCTAssertEqual(code, 0)
        let store = CapabilityStore(path: dir + "/config/capabilities.json")
        let record = store.record(for: QualificationIdentity(
            engineer: .kimi, lane: "native", model: "fake-model"))
        XCTAssertTrue(record?.notes?.contains("continuity: pass") ?? false,
                      record?.notes ?? "no notes")
    }
}
