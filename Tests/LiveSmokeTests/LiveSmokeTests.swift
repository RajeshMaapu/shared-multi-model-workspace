import XCTest
import WorkshopDaemonKit
import WorkshopService
import WorkshopStore
import WorkshopCore

/// Live smoke tests against the real Devin/Kimi/DeepSeek accounts.
/// Opt-in: every test XCTSkips unless WORKSHOP_LIVE=1. Bounded synthetic
/// tasks only; each turn is tiny. Run:
///   WORKSHOP_LIVE=1 swift test --filter LiveSmokeTests
final class LiveSmokeTests: XCTestCase {
    private static var home = ""
    private static var runtimeDir = ""
    private static var runtime: DaemonRuntime?
    private static var taskByEngineer: [EngineerID: TaskID] = [:]
    private static var nonceByEngineer: [EngineerID: String] = [:]

    private static var repoRoot: String {
        // <repo>/Tests/LiveSmokeTests/LiveSmokeTests.swift → <repo>
        ((#filePath as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent + "/.."
    }

    private static var evidenceDir: String {
        ((repoRoot as NSString).standardizingPath)
            + "/docs/evidence/phase2/live"
    }

    private static var bridgePath: String {
        ((repoRoot as NSString).standardizingPath) + "/.build/debug/workshop-mcp"
    }

    /// Boot the shared runtime once (throwaway home + runtime dir under /tmp).
    private func boot() async throws -> DaemonRuntime {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WORKSHOP_LIVE"] == "1",
            "WORKSHOP_LIVE not set")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.bridgePath),
            "workshop-mcp not built (run swift build first)")
        if let runtime = Self.runtime { return runtime }
        var homeBuf = [CChar](repeating: 0, count: 64)
        var rtBuf = [CChar](repeating: 0, count: 64)
        strcpy(&homeBuf, "/tmp/wl.XXXXXX")
        strcpy(&rtBuf, "/tmp/wr.XXXXXX")
        struct BootError: Error {}
        guard mkdtemp(&homeBuf) != nil, mkdtemp(&rtBuf) != nil else {
            throw BootError()
        }
        Self.home = String(cString: homeBuf)
        Self.runtimeDir = String(cString: rtBuf)
        setenv("WORKSHOP_DIAG_DIR", Self.home + "/diagnostics", 1)
        var env = ProcessInfo.processInfo.environment
        env["WORKSHOP_ADAPTERS"] = "live"
        env["WORKSHOP_MCP_PATH"] = Self.bridgePath
        env["WORKSHOP_RUNTIME_DIR"] = Self.runtimeDir
        let runtime = try DaemonRuntime(home: Self.home, runtimeDir: Self.runtimeDir,
                                        env: env)
        try await runtime.start()
        Self.runtime = runtime
        return runtime
    }

    private func repo() throws -> WorkshopRepository {
        WorkshopRepository(db: try Database(path: Self.home + "/db/workshop.sqlite"))
    }

    private static func nonce() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    /// Poll until a predicate over committed messages holds or the deadline hits.
    private func waitFor(_ runtime: DaemonRuntime, taskID: TaskID,
                         timeout: TimeInterval,
                         _ pred: @escaping ([Message]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let messages = (try? await runtime.service.readMessages(taskID)) ?? []
            if pred(messages) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Persist one test's evidence JSON under docs/evidence/<phase>/live/.
    private func record(_ name: String, _ data: [String: JSONValue],
                        phase: String = "phase2") {
        let dir = Self.evidenceDir.replacingOccurrences(of: "phase2", with: phase)
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        var payload = data
        payload["test"] = .string(name)
        payload["recorded_at"] = .string(WorkshopTime.string(Date()))
        guard let json = try? JSONEncoder().encode(JSONValue.object(payload)) else { return }
        try? json.write(to: URL(fileURLWithPath: dir + "/" + name + ".json"))
    }

    private func usageEvidence(_ runtime: DaemonRuntime, taskID: TaskID,
                               engineer: EngineerID) async throws -> JSONValue {
        let rows = try await runtime.service.listUsage(taskID)
            .filter { $0.engineerID == engineer }
        guard let last = rows.last else { return .null }
        return .object([
            "input": last.sample.input.map { .number(Double($0)) } ?? .null,
            "output": last.sample.output.map { .number(Double($0)) } ?? .null,
            "cache_read": last.sample.cacheRead.map { .number(Double($0)) } ?? .null,
            "cache_write": last.sample.cacheWrite.map { .number(Double($0)) } ?? .null,
            "source": .string(last.sample.source),
            "model": last.model.map(JSONValue.string) ?? .null,
            "native_session_id": last.nativeSessionID.map(JSONValue.string) ?? .null,
            "row_count": .number(Double(rows.count)),
        ])
    }

    /// L1..L3: one engineer, tiny tool-call task.
    private func runSingle(_ engineer: EngineerID) async throws {
        let started = Date()
        let runtime = try await boot()
        let nonce = Self.nonce()
        Self.nonceByEngineer[engineer] = nonce
        let marker = "WORKSHOP_LIVE_\(engineer.rawValue.uppercased())_OK_\(nonce)"
        let brief = "Call the workshop_post_message tool once with body exactly "
            + "`\(marker)` (task_id is given in your context). "
            + "Then reply with the single word done."
        let receipt = try await runtime.service.createTask(CreateTaskRequest(
            idempotencyKey: "live-\(engineer.rawValue)-\(nonce)",
            title: "Live smoke \(engineer.rawValue)", objective: brief,
            phase: .execution, participants: [engineer]))
        Self.taskByEngineer[engineer] = receipt.taskID

        let found = await waitFor(runtime, taskID: receipt.taskID, timeout: 240) {
            $0.contains {
                $0.author == .engineer(engineer) && $0.deliveryState == .committed
                    && $0.body.contains(marker)
            }
        }
        // The tool-posted marker lands mid-turn; usage rows are written when the
        // prompt result arrives, so give the turn a short grace period.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let u = try? await usageEvidence(runtime, taskID: receipt.taskID,
                                                engineer: engineer),
               u["row_count"] != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let detail = try await runtime.service.getTask(receipt.taskID)
        let usage = try await usageEvidence(runtime, taskID: receipt.taskID,
                                            engineer: engineer)
        let binding = try repo().sessionBinding(taskID: receipt.taskID,
                                                engineerID: engineer, role: "owner",
                                                workerID: "main")
        let sessionFile = Self.home + "/sessions/deepseek/"
            + receipt.taskID.rawValue + "/main.json"
        var evidence: [String: JSONValue] = [
            "engineer": .string(engineer.rawValue),
            "nonce_marker": .string(marker),
            "marker_message_found": .bool(found),
            "task_state": .string(detail.task.state.rawValue),
            "wall_seconds": .number(Date().timeIntervalSince(started)),
            "usage": usage,
            "session_binding": binding?.nativeSessionID.map(JSONValue.string) ?? .null,
            "deepseek_session_file": .bool(
                FileManager.default.fileExists(atPath: sessionFile)),
        ]
        if let probe = await runtime.service.listEngineers()
            .first(where: { $0.engineer == engineer }) {
            evidence["probe_health"] = .string(probe.health.detail)
            evidence["probe_tested"] = .bool(probe.tested)
            evidence["versions"] = .object(
                probe.versions.mapValues { .string($0) })
            evidence["effective_model"] = probe.effectiveModel
                .map(JSONValue.string) ?? .null
        }
        record("L-\(engineer.rawValue)", evidence)
        XCTAssertTrue(found, "\(engineer.rawValue) did not post \(marker)")
        XCTAssertNotNil(usage["row_count"], "no usage_samples row")
        if engineer == .deepseek {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile))
        } else {
            XCTAssertFalse(binding?.nativeSessionID?.isEmpty ?? true)
        }
    }

    func testL1Devin() async throws { try await runSingle(.devin) }
    func testL2Kimi() async throws { try await runSingle(.kimi) }
    func testL3DeepSeek() async throws { try await runSingle(.deepseek) }

    /// L4: peer roundtrip — Devin mentions @kimi, Kimi replies and mentions
    /// @deepseek, DeepSeek replies. Wakeup chain only; ≤5 engineer turns.
    func testL4PeerRoundtrip() async throws {
        let started = Date()
        let runtime = try await boot()
        let nonce = Self.nonce()
        let brief = "Follow these instructions exactly. "
            + "Devin: use the workshop_post_message tool to post a message whose "
            + "body mentions @kimi and asks Kimi to reply with `KIMI_ACK_\(nonce)`. "
            + "Kimi: when woken, use workshop_post_message to post a reply whose "
            + "body contains `KIMI_ACK_\(nonce)` AND the mention @deepseek, asking "
            + "DeepSeek to reply with `DEEPSEEK_ACK_\(nonce)`. "
            + "DeepSeek: when woken, use workshop_post_message to post a reply "
            + "whose body contains `DEEPSEEK_ACK_\(nonce)`. "
            + "Everyone: do nothing else."
        let receipt = try await runtime.service.createTask(CreateTaskRequest(
            idempotencyKey: "live-peer-\(nonce)",
            title: "Live peer roundtrip", objective: brief,
            phase: .execution, participants: [.devin, .kimi, .deepseek]))
        let ok = await waitFor(runtime, taskID: receipt.taskID, timeout: 480) { ms in
            let devin = ms.contains {
                $0.author == .engineer(.devin) && $0.deliveryState == .committed
                    && $0.body.contains("@kimi") }
            let kimi = ms.contains {
                $0.author == .engineer(.kimi) && $0.deliveryState == .committed
                    && $0.body.contains("KIMI_ACK_\(nonce)")
                    && $0.body.contains("@deepseek") }
            let ds = ms.contains {
                $0.author == .engineer(.deepseek) && $0.deliveryState == .committed
                    && $0.body.contains("DEEPSEEK_ACK_\(nonce)") }
            return devin && kimi && ds
        }
        let messages = (try? await runtime.service.readMessages(receipt.taskID)) ?? []
        let wakeups = try repo().wakeups(receipt.taskID)
        let suppressed = wakeups.filter { $0.state == "suppressed" }
        let engineerTurns = wakeups.filter { $0.state == "done" }.count + 1 // +1 owner turn
        record("L-peer", [
            "nonce": .string(nonce),
            "chain_completed": .bool(ok),
            "wall_seconds": .number(Date().timeIntervalSince(started)),
            "wakeup_rows": .number(Double(wakeups.count)),
            "suppressed": .number(Double(suppressed.count)),
            "engineer_turns": .number(Double(engineerTurns)),
            "engineer_messages": .number(Double(messages.filter {
                if case .engineer = $0.author { return true }; return false }.count)),
        ])
        XCTAssertTrue(ok, "peer chain did not complete")
        XCTAssertTrue(suppressed.isEmpty, "wakeups were suppressed unexpectedly")
        XCTAssertLessThanOrEqual(engineerTurns, 5)
    }

    /// L5: restart recall — reopen on the same home, set the consumed cursor so
    /// the packet contains only the new user message, verify native session
    /// memory recalls the nonce (T18-lite, §12.3). Devin + Kimi only.
    func testL5RestartRecall() async throws {
        let runtime = try await boot()
        var subjects: [EngineerID] = []
        for e in [EngineerID.devin, .kimi] {
            if Self.taskByEngineer[e] != nil, Self.nonceByEngineer[e] != nil {
                subjects.append(e)
            }
        }
        try XCTSkipIf(subjects.isEmpty, "L1/L2 must run first to create sessions")

        // Close and reopen on the same WORKSHOP_HOME.
        await runtime.shutdown()
        Self.runtime = nil
        var env = ProcessInfo.processInfo.environment
        env["WORKSHOP_ADAPTERS"] = "live"
        env["WORKSHOP_MCP_PATH"] = Self.bridgePath
        env["WORKSHOP_RUNTIME_DIR"] = Self.runtimeDir
        let reopened = try DaemonRuntime(home: Self.home, runtimeDir: Self.runtimeDir,
                                         env: env)
        try await reopened.start()
        Self.runtime = reopened

        // Consume the cursor so the packet carries only the new user message.
        var packets: [EngineerID: String] = [:]
        let packetLock = NSLock()
        await reopened.service.setPacketInspector { engineer, text in
            packetLock.lock(); packets[engineer] = text; packetLock.unlock()
        }

        var results: [String: JSONValue] = [:]
        var recalledBy: [EngineerID: Bool] = [:]
        for engineer in subjects {
            let taskID = Self.taskByEngineer[engineer]!
            let nonce = Self.nonceByEngineer[engineer]!
            let messages = try await reopened.service.readMessages(taskID)
            let maxSeq = messages.map(\.seq).max() ?? 0
            try repo().setLastReadSeq(taskID, engineer, seq: maxSeq, at: Date())
            _ = try await reopened.service.postMessage(
                taskID: taskID,
                body: "Reply with only the nonce you posted earlier in this task.",
                principal: .user)
            let recalled = await waitFor(reopened, taskID: taskID, timeout: 240) { ms in
                ms.contains {
                    $0.author == .engineer(engineer)
                        && $0.deliveryState == .committed
                        && $0.seq > maxSeq + 1 // newer than the user reply
                        && $0.body.contains(nonce) }
            }
            packetLock.lock()
            let packet = packets[engineer]
            packetLock.unlock()
            recalledBy[engineer] = recalled
            // The nonce alone appears verbatim in the task brief, so the
            // meaningful check is that the earlier posted message line
            // ("[seq] <name>: <marker>") is absent from the packet.
            let marker = "WORKSHOP_LIVE_\(engineer.rawValue.uppercased())_OK_\(nonce)"
            let leaked = packet?.contains(": \(marker)") ?? false
            results[engineer.rawValue] = .object([
                "nonce": .string(nonce),
                "recalled": .bool(recalled),
                "packet_captured": .bool(packet != nil),
                "packet_omitted_prior_message": .bool(packet != nil && !leaked),
            ])
            if let packet {
                XCTAssertFalse(leaked,
                               "packet contains the earlier posted message — test is vacuous")
            } else {
                XCTFail("no turn ran for \(engineer.rawValue) after restart")
            }
        }
        record("L-restart", results)
        for engineer in subjects {
            XCTAssertTrue(recalledBy[engineer] == true,
                          "\(engineer.rawValue) did not recall its nonce after restart")
        }
    }

    /// L6: full Phase 3 loop — research → proposals → cross-review → Devin
    /// report → user approval → Devin allocation → owner result. Each stage is
    /// time-boxed; a timeout records the failure and fails the test.
    func testL6ResearchApprovalAllocation() async throws {
        let started = Date()
        let runtime = try await boot()
        let service = runtime.service
        let nonce = Self.nonce()
        var stageTimes: [String: Double] = [:]
        func mark(_ stage: String) {
            stageTimes[stage] = Date().timeIntervalSince(started)
        }

        let brief = "Decide whether Workshop should store artifact previews "
            + "as PNG or SVG. Keep your proposal under 120 words; one "
            + "alternative; one risk; propose one subtask named "
            + "'Write preview decision note' owned by yourself. "
            + "Marker: \(nonce)."
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: "live-l6-\(nonce)",
            title: "Artifact preview format", objective: brief,
            phase: .researchProposal,
            participants: [.devin, .kimi, .deepseek]))
        let taskID = receipt.taskID

        // Stage 1: all three drafts (≤6 min), then publish.
        var ok = await waitFor(runtime, taskID: taskID, timeout: 360) { _ in
            ((try? self.repo().proposals(taskID)) ?? []).count == 3
        }
        mark("drafts")
        XCTAssertTrue(ok, "timed out waiting for three proposal drafts")
        guard ok else {
            await recordL6(taskID, stageTimes, started, failed: "drafts"); return }
        try await service.publishProposals(taskID)
        mark("published")

        // Stage 2: cross-review — every participant submits ≥1 review (≤6 min).
        ok = await waitFor(runtime, taskID: taskID, timeout: 360) { messages in
            let reviewers = Set(messages.filter { $0.kind == .review }
                .compactMap { $0.author.engineerID })
            return reviewers.count == 3
        }
        mark("reviews")
        XCTAssertTrue(ok, "timed out waiting for cross-reviews")
        guard ok else {
            await recordL6(taskID, stageTimes, started, failed: "reviews"); return }

        // Stage 3: Devin consolidates a report (≤4 min).
        ok = await waitFor(runtime, taskID: taskID, timeout: 240) { _ in
            ((try? self.repo().reports(taskID)) ?? []).isEmpty == false
        }
        mark("report")
        XCTAssertTrue(ok, "timed out waiting for Devin's report")
        guard ok else {
            await recordL6(taskID, stageTimes, started, failed: "report"); return }
        let revision = ((try? self.repo().reports(taskID)) ?? []).map(\.revision).max() ?? 0

        // Stage 4: user approves the current revision.
        try await service.approveArchitecture(taskID: taskID,
                                              reportRevision: revision,
                                              scope: nil, principal: .user)
        mark("approved")

        // Stage 5: Devin allocates — some subtask gains an owner (≤4 min).
        ok = await waitFor(runtime, taskID: taskID, timeout: 240) { _ in
            ((try? self.repo().subtasks(taskID)) ?? []).contains { $0.ownerID != nil }
        }
        mark("allocated")
        XCTAssertTrue(ok, "timed out waiting for Devin's allocation")
        guard ok else {
            await recordL6(taskID, stageTimes, started, failed: "allocated"); return }

        // Stage 6: the owner reports a result (≤4 min): a structured result
        // card or the subtask leaving the working/claimed state.
        ok = await waitFor(runtime, taskID: taskID, timeout: 240) { messages in
            messages.contains {
                $0.structured?.contains("result") == true && $0.kind != .systemEvent
            } || ((try? self.repo().subtasks(taskID)) ?? []).contains {
                $0.ownerID != nil && ($0.state == .review || $0.state == .done)
            }
        }
        mark("result")
        await recordL6(taskID, stageTimes, started, failed: ok ? nil : "result")
        XCTAssertTrue(ok, "timed out waiting for the owner's result")
    }

    /// Write L6 evidence (docs/evidence/phase3/live/l6.json + live-l6.md).
    private func recordL6(_ taskID: TaskID, _ stageTimes: [String: Double],
                          _ started: Date, failed: String?) async {
        guard let runtime = Self.runtime else { return }
        let msgs = (try? await runtime.service.readMessages(taskID)) ?? []
        let wakeups = (try? self.repo().wakeups(taskID)) ?? []
        var usage: [String: JSONValue] = [:]
        for e in EngineerID.allCases {
            usage[e.rawValue] = (try? await usageEvidence(
                runtime, taskID: taskID, engineer: e)) ?? .null
        }
        record("l6", [
            "stage_times": .object(stageTimes.mapValues { .number($0) }),
            "wall_seconds": .number(Date().timeIntervalSince(started)),
            "failed_stage": failed.map(JSONValue.string) ?? .null,
            "message_rows": .number(Double(msgs.count)),
            "wakeup_rows": .number(Double(wakeups.count)),
            "wakeups_done": .number(Double(wakeups.filter {
                $0.state == "done" }.count)),
            "wakeups_suppressed": .number(Double(wakeups.filter {
                $0.state == "suppressed" }.count)),
            "usage": .object(usage),
        ], phase: "phase3")
        var md = "# L6 live evidence — research → approval → allocation\n\n"
        md += "| stage | t+seconds |\n|---|---|\n"
        for stage in ["drafts", "published", "reviews", "report", "approved",
                      "allocated", "result"] {
            let cell = stageTimes[stage].map { String(format: "%.1f", $0) } ?? "—"
            md += "| \(stage) | \(cell) |\n"
        }
        md += "\n- Wall time: "
            + String(format: "%.1f", Date().timeIntervalSince(started)) + " s\n"
        md += "- Messages: \(msgs.count); wakeups: \(wakeups.count) "
            + "(done \(wakeups.filter { $0.state == "done" }.count), "
            + "suppressed \(wakeups.filter { $0.state == "suppressed" }.count))\n"
        if let failed { md += "- **Failed stage:** \(failed)\n" }
        let dir = Self.evidenceDir.replacingOccurrences(of: "phase2",
                                                      with: "phase3")
        try? md.write(toFile: dir + "/live-l6.md", atomically: true,
                      encoding: .utf8)
    }

    override class func tearDown() {
        // Nothing to kill by hand: adapter processes are children of the test
        // process group and exit with it; the runtime shuts down in-test.
    }
}
