import XCTest
@testable import WorkshopAdapters
@testable import WorkshopService
@testable import WorkshopCore

/// Managed runtime lane (D-b): provider-generalized tool loop, Workshop-owned
/// local tools, Kimi OAuth credentials, and lane selection. All transports
/// are fakes; no live processes or network calls.
final class ManagedLaneTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-managed-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private final class Recorder: @unchecked Sendable {
        var bodies: [[String: JSONValue]] = []
        let lock = NSLock()
        func append(_ b: [String: JSONValue]) { lock.lock(); bodies.append(b); lock.unlock() }
    }

    private struct StubHTTP: HTTPTransport {
        var responses: [(Int, JSONValue)]
        var recorded: Recorder
        func postJSON(url: URL, headers: [String: String],
                      body: [String: JSONValue]) async throws -> (status: Int, body: JSONValue) {
            recorded.append(body)
            let idx = min(recorded.bodies.count - 1, responses.count - 1)
            return responses[idx]
        }
    }

    private func finalResponse(_ text: String = "done") -> JSONValue {
        .object([
            "choices": .array([.object(["message": .object([
                "content": .string(text), "tool_calls": .null])])]),
            "usage": .object(["prompt_tokens": .number(10),
                              "completion_tokens": .number(3)]),
        ])
    }

    private func toolCallResponse(_ name: String, _ args: String,
                                  id: String = "call_1") -> JSONValue {
        .object([
            "choices": .array([.object(["message": .object([
                "content": .null,
                "tool_calls": .array([.object([
                    "id": .string(id),
                    "function": .object([
                        "name": .string(name),
                        "arguments": .string(args)])])])])])]),
            "usage": .object(["prompt_tokens": .number(10),
                              "completion_tokens": .number(3)]),
        ])
    }

    private func context(workspace: String? = nil) -> TurnContext {
        let task = WorkshopTask(id: TaskID("task_m"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(),
                                updatedAt: Date())
        return TurnContext(task: task, subtask: nil, recentMessages: [],
                           workspace: workspace.map {
                               TaskWorkspace(taskID: TaskID("task_m"),
                                             path: $0, state: "discussion") })
    }

    private func collect(_ adapter: EngineerAdapter, ref: SessionRef,
                         context: TurnContext) async -> [AdapterEvent] {
        var events: [AdapterEvent] = []
        let stream = adapter.sendTurn(ref: ref, turnID: "t", context: context,
                                      deadline: Date().addingTimeInterval(30))
        do {
            for try await e in stream { events.append(e) }
        } catch { events.append(.uncertain("threw: \(error.localizedDescription)")) }
        return events
    }

    // MARK: - a. Managed Kimi turn

    /// A managed-lane Kimi turn: model k3 on the wire, no thinking extras,
    /// lane-local read_file executed against the workspace, plus the
    /// workshop tool catalog in the request.
    func testManagedKimiTurnWithLocalTools() async throws {
        let ws = dir + "/gen-x/workspace"
        try FileManager.default.createDirectory(atPath: ws, withIntermediateDirectories: true)
        try "readme-contents".write(toFile: ws + "/README.md",
                                    atomically: true, encoding: .utf8)
        let recorded = Recorder()
        let adapter = ManagedRuntimeAdapter(
            engineer: .kimi, provider: .kimi(),
            transport: StubHTTP(responses: [
                (200, toolCallResponse("read_file", #"{"path":"README.md"}"#)),
                (200, finalResponse()),
            ], recorded: recorded),
            sessionsDir: dir + "/sessions/kimi",
            keyReader: { "oauth-token" },
            workshopToolExecutor: { _, _ in #"{"ok":true}"# },
            sandboxProfileProvider: { _ in
                throw WorkshopError.invalidRequest("no profile in test")
            },
            localTools: true)
        let ref = SessionRef(engineer: .kimi, nativeSessionID: "kimi:task_m:main")
        let events = await collect(adapter, ref: ref, context: context(workspace: ws))

        XCTAssertTrue(events.contains(.messageDelta("done")))
        XCTAssertTrue(events.contains(.turnCompleted))
        XCTAssertTrue(events.contains(.toolActivity(title: "read_file",
                                                    status: "calling")))
        let first = recorded.bodies[0]
        XCTAssertEqual(first["model"]?.stringValue, "k3")
        XCTAssertNil(first["thinking"])
        XCTAssertNil(first["reasoning_effort"])
        let toolNames = (first["tools"]?.arrayValue ?? []).compactMap {
            $0["function"]?["name"]?.stringValue
        }
        XCTAssertTrue(toolNames.contains("read_file"))
        XCTAssertTrue(toolNames.contains("exec"))
        XCTAssertTrue(toolNames.contains("workshop_post_message"))
        // The local tool result was echoed back to the provider.
        let second = recorded.bodies[1]
        let toolMsg = second["messages"]?.arrayValue?.first {
            $0["role"]?.stringValue == "tool"
        }
        XCTAssertEqual(toolMsg?["tool_call_id"]?.stringValue, "call_1")
        XCTAssertTrue(toolMsg?["content"]?.stringValue?
            .contains("readme-contents") ?? false)
        // Session id + history path follow the provider name.
        let hist = dir + "/sessions/kimi/clean-v2/task_m/main.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: hist))
    }

    // MARK: - c. Local tools confinement

    private func localTools() throws -> (ManagedLocalTools, String) {
        let ws = dir + "/gen-lt/workspace"
        try FileManager.default.createDirectory(atPath: ws, withIntermediateDirectories: true)
        return (ManagedLocalTools(workspace: ws, sandboxProfile: nil), ws)
    }

    private func field(_ json: String, _ key: String) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?[key]?
            .stringValue
    }

    func testReadFileRejectsEscape() throws {
        let (tools, _) = try localTools()
        let out = tools.execute(name: "read_file",
                                args: .object(["path": .string("../etc/passwd")]))!
        XCTAssertTrue(field(out, "error")?.contains("outside workspace") ?? false)
        let abs = tools.execute(name: "read_file",
                                args: .object(["path": .string("/etc/passwd")]))!
        XCTAssertTrue(field(abs, "error")?.contains("outside workspace") ?? false)
    }

    func testReadFileRejectsSymlinkEscape() throws {
        let (tools, ws) = try localTools()
        let outside = dir + "/outside-secret.txt"
        try "secret".write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: ws + "/link.txt",
                                                   withDestinationPath: outside)
        let out = tools.execute(name: "read_file",
                                args: .object(["path": .string("link.txt")]))!
        XCTAssertNotNil(field(out, "error"))
        XCTAssertFalse(out.contains("secret"))
    }

    func testWriteFileCreatesInsideWorkspace() throws {
        let (tools, ws) = try localTools()
        let out = tools.execute(name: "write_file",
                                args: .object(["path": .string("sub/new.txt"),
                                               "content": .string("hello")]))!
        XCTAssertNil(field(out, "error"))
        XCTAssertEqual(try String(contentsOfFile: ws + "/sub/new.txt"), "hello")
        let list = tools.execute(name: "list_dir",
                                 args: .object(["path": .string("sub")]))!
        XCTAssertTrue(list.contains("new.txt"))
    }

    func testExecSandboxedEchoTimeoutAndUnavailable() throws {
        let ws = dir + "/gen-ex/workspace"
        try FileManager.default.createDirectory(atPath: ws, withIntermediateDirectories: true)
        let profile = dir + "/test.sb"
        try "(version 1) (allow default)".write(toFile: profile, atomically: true,
                                                encoding: .utf8)
        let sandboxed = ManagedLocalTools(workspace: ws, sandboxProfile: profile)

        let echo = sandboxed.execute(name: "exec",
                                     args: .object(["command": .string("echo hi")]))!
        XCTAssertEqual(field(echo, "stdout"), "hi\n")
        XCTAssertEqual(echo.contains("\"exit_code\":0"), true, echo)

        let start = Date()
        let timeout = sandboxed.execute(
            name: "exec",
            args: .object(["command": .string("sleep 5"),
                           "timeout_seconds": .number(1)]))!
        XCTAssertTrue(field(timeout, "error")?.contains("timeout") ?? false)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)

        let unconfined = ManagedLocalTools(workspace: ws, sandboxProfile: nil)
        let denied = unconfined.execute(name: "exec",
                                        args: .object(["command": .string("echo hi")]))!
        XCTAssertTrue(field(denied, "error")?
            .contains("exec unavailable") ?? false)
    }

    // MARK: - d. Compaction invariants (G-D7)

    /// Property: over random histories, compacted output starts (post-summary)
    /// on a user message and every tool message keeps its assistant call.
    func testCompactionKeepsCompleteToolSequences() async throws {
        var rng = SystemRandomNumberGenerator()
        let adapter = DeepSeekAdapter(
            transport: StubHTTP(responses: [(200, finalResponse())],
                                recorded: Recorder()),
            sessionsDir: dir + "/sessions",
            endpoint: URL(string: "https://example.invalid/api")!,
            keyReader: { "sk-test" },
            toolExecutor: { _, _ in "{}" })
        for _ in 0..<200 {
            var history: [JSONValue] = [.object([
                "role": .string("system"), "content": .string("sys")])]
            var callID = 0
            let turns = 30 + Int.random(in: 0...30, using: &rng)
            for t in 0..<turns {
                history.append(.object([
                    "role": .string("user"),
                    "content": .string("turn \(t) " + String(repeating: "x", count: 200))]))
                for _ in 0..<Int.random(in: 0...3, using: &rng) {
                    callID += 1
                    history.append(.object([
                        "role": .string("assistant"),
                        "content": .null,
                        "tool_calls": .array([.object([
                            "id": .string("c\(callID)"),
                            "function": .object([
                                "name": .string("workshop_get_task"),
                                "arguments": .string("{}")])])])]))
                    history.append(.object([
                        "role": .string("tool"),
                        "tool_call_id": .string("c\(callID)"),
                        "content": .string("{}")]))
                }
            }
            let (kept, compacted) = await adapter.compactedHistory(
                history, taskID: TaskID("task_m"))
            XCTAssertTrue(compacted) // every generated history exceeds 60 msgs
            // The kept slice begins at a user message after the summary.
            XCTAssertEqual(kept[0]["role"]?.stringValue, "system")
            XCTAssertTrue(kept[0]["content"]?.stringValue?
                .contains("compaction summary") ?? false)
            XCTAssertEqual(kept[1]["role"]?.stringValue, "user")
            var seenCalls = Set<String>()
            var inAssistantCalls: Set<String> = []
            for (i, m) in kept.enumerated() {
                switch m["role"]?.stringValue {
                case "assistant":
                    inAssistantCalls = Set(
                        (m["tool_calls"]?.arrayValue ?? []).compactMap {
                            $0["id"]?.stringValue })
                    seenCalls.formUnion(inAssistantCalls)
                case "tool":
                    let id = m["tool_call_id"]?.stringValue ?? ""
                    XCTAssertTrue(seenCalls.contains(id),
                                  "tool message \(id) at \(i) lacks its assistant call")
                default:
                    break
                }
            }
        }
    }

    // MARK: - e. Kimi OAuth credential reader

    private func kimiConfig() throws -> (config: String, creds: String) {
        let config = dir + "/kimi-config.toml"
        let creds = dir + "/kimi-creds"
        try FileManager.default.createDirectory(atPath: creds,
                                                withIntermediateDirectories: true)
        try """
        default_model = "kimi-code/k3"

        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/test-grant"
        """.write(toFile: config, atomically: true, encoding: .utf8)
        return (config, creds)
    }

    func testKimiCredentialReader() async throws {
        let (config, creds) = try kimiConfig()
        try #"{"access_token":"tok-abc","expires_at":4102444800}"#
            .write(toFile: creds + "/test-grant.json",
                   atomically: true, encoding: .utf8)
        let token = try await KimiOAuthCredential.readAccessToken(
            configPath: config, credentialsDir: creds)
        XCTAssertEqual(token, "tok-abc")
    }

    func testKimiCredentialExpiredIsLoginRequired() async throws {
        let (config, creds) = try kimiConfig()
        try #"{"access_token":"tok-old","expires_at":1000}"#
            .write(toFile: creds + "/test-grant.json",
                   atomically: true, encoding: .utf8)
        do {
            _ = try await KimiOAuthCredential.readAccessToken(
                configPath: config, credentialsDir: creds)
            XCTFail("expired grant must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Login required"))
            XCTAssertEqual(StartupFailureClass.classify(
                error.localizedDescription), .auth)
        }
        // ISO-8601 expiry in the past also fails as auth.
        try #"{"access_token":"tok-old","expires_at":"2020-01-01T00:00:00Z"}"#
            .write(toFile: creds + "/test-grant.json",
                   atomically: true, encoding: .utf8)
        do {
            _ = try await KimiOAuthCredential.readAccessToken(
                configPath: config, credentialsDir: creds)
            XCTFail("expired grant must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Login required"))
        }
    }

    /// The CLI owns the rotating refresh grant; when the file's token is
    /// expired the hook runs and the file is re-read.
    func testKimiCredentialRefreshHookRenewsToken() async throws {
        let (config, creds) = try kimiConfig()
        let grant = creds + "/test-grant.json"
        try #"{"access_token":"tok-old","expires_at":1000}"#
            .write(toFile: grant, atomically: true, encoding: .utf8)
        let token = try await KimiOAuthCredential.readAccessToken(
            configPath: config, credentialsDir: creds, kimiBinary: "kimi",
            refreshViaCLI: { _ in
                let future = Int(Date().timeIntervalSince1970) + 900
                let json = "{\"access_token\":\"tok-new\",\"expires_at\":\(future)}"
                try json.write(toFile: grant, atomically: true, encoding: .utf8)
                return KimiCLIRefresh.RefreshReport()
            })
        XCTAssertEqual(token, "tok-new")
    }

    /// A hook that cannot refresh still yields the login-required error.
    func testKimiCredentialRefreshHookFailureStillLoginRequired() async throws {
        let (config, creds) = try kimiConfig()
        try #"{"access_token":"tok-old","expires_at":1000}"#
            .write(toFile: creds + "/test-grant.json",
                   atomically: true, encoding: .utf8)
        do {
            _ = try await KimiOAuthCredential.readAccessToken(
                configPath: config, credentialsDir: creds, kimiBinary: "kimi",
                refreshViaCLI: { _ in KimiCLIRefresh.RefreshReport() })
            XCTFail("expired grant must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Login required"))
        }
    }

    func testKimiCredentialMissingFile() async throws {
        let (config, creds) = try kimiConfig()
        do {
            _ = try await KimiOAuthCredential.readAccessToken(
                configPath: config, credentialsDir: creds)
            XCTFail("missing grant must throw")
        } catch {}
    }

    // MARK: - f. Lane selection

    private struct AnyError: Error, LocalizedError {
        var errorDescription: String? { message }
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func observedLanes() -> ((TaskID, EngineerID, String) async -> Void,
                                     Locked<[String]>) {
        let lanes = Locked<[String]>([])
        return ({ _, _, lane in lanes.with { $0.append(lane) } }, lanes)
    }

    /// auth-class native failure falls back to managed on the first call.
    func testLaneFallbackOnAuthFailure() async throws {
        let native = FakeAdapter(engineer: .kimi)
        native.openSessionError = AnyError(
            "ACP remote error -32000: Authentication required")
        let managed = FakeAdapter(engineer: .kimi)
        let (observer, lanes) = observedLanes()
        let selector = LaneSelectingAdapter(engineer: .kimi, native: native,
                                            managed: managed,
                                            laneObserver: observer)
        let binding = SessionBinding(taskID: TaskID("task_m"),
                                     engineerID: .kimi, role: "owner",
                                     workerID: "main")
        let ref = try await selector.openTaskSession(binding: binding)
        XCTAssertTrue(ref.nativeSessionID.hasPrefix("managed:"))
        XCTAssertEqual(lanes.with { $0 }, ["managed"])
        // The managed turn announces the fallback first.
        let events = await collect(selector, ref: ref, context: context())
        guard case .uncertain(let note) = events.first else {
            XCTFail("expected an uncertain fallback note first, got \(events)")
            return
        }
        XCTAssertTrue(note.contains("(auth)"), note)
        XCTAssertTrue(note.contains("managed lane"), note)
    }

    /// Non-auth classes need two prior native failures before falling back;
    /// a native success resets the counter.
    func testLaneFallbackAfterTwoFailuresAndReset() async throws {
        let (observer, lanes) = observedLanes()
        let native = FakeAdapter(engineer: .kimi)
        let managed = FakeAdapter(engineer: .kimi)
        let selector = LaneSelectingAdapter(engineer: .kimi, native: native,
                                            managed: managed,
                                            laneObserver: observer)
        let binding = SessionBinding(taskID: TaskID("task_m"),
                                     engineerID: .kimi, role: "owner",
                                     workerID: "main")
        native.openSessionError = AnyError("kimi session/new failed: "
            + "ACP session/new timed out")
        for _ in 0..<2 {
            do {
                _ = try await selector.openTaskSession(binding: binding)
                XCTFail("timeout-class failure must rethrow")
            } catch {}
        }
        let ref = try await selector.openTaskSession(binding: binding)
        XCTAssertTrue(ref.nativeSessionID.hasPrefix("managed:"))

        // A native success resets the counter and reports the native lane.
        let fresh = LaneSelectingAdapter(engineer: .kimi, native: native,
                                         managed: managed,
                                         laneObserver: observer)
        native.openSessionError = AnyError("timed out")
        do {
            _ = try await fresh.openTaskSession(binding: binding)
            XCTFail("first failure after reset must rethrow")
        } catch {}
        native.openSessionError = nil
        let nativeRef = try await fresh.openTaskSession(binding: binding)
        XCTAssertFalse(nativeRef.nativeSessionID.hasPrefix("managed:"))
        XCTAssertEqual(lanes.with { $0 }, ["managed", "native"])
    }
}

/// Tiny locked box for the lane observer (mirrors the test helpers).
private final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return f(&value)
    }
}

extension ManagedLaneTests {
    /// Zero-inference canary: the grant file only needs a refresh_token —
    /// the access token's expiry is irrelevant since the CLI renews it at
    /// launch. An absent file reports missing; no refresh_token reports
    /// unreadable.
    func testKimiCanaryReportsRefreshTokenPresence() async throws {
        let (config, creds) = try kimiConfig()
        let grant = creds + "/test-grant.json"
        let home = dir + "/canary-home"
        try FileManager.default.createDirectory(
            atPath: home + "/profiles/clean-v2/kimi/credentials",
            withIntermediateDirectories: true)
        var result = await CredentialCanary.check(
            engineer: .kimi, home: home,
            kimiConfigPath: config, kimiCredentialsDir: creds)
        XCTAssertEqual(result.0, .missing)
        // Expired access token + refresh_token: ok, never expired.
        try #"{"access_token":"tok-old","refresh_token":"rt","expires_at":1000}"#
            .write(toFile: grant, atomically: true, encoding: .utf8)
        result = await CredentialCanary.check(
            engineer: .kimi, home: home,
            kimiConfigPath: config, kimiCredentialsDir: creds)
        XCTAssertEqual(result.0, .ok)
        XCTAssertTrue(result.1.contains("refreshed by the Kimi CLI"), result.1)
        // No refresh_token: unreadable.
        try #"{"access_token":"tok-x","expires_at":9999999999}"#
            .write(toFile: grant, atomically: true, encoding: .utf8)
        result = await CredentialCanary.check(
            engineer: .kimi, home: home,
            kimiConfigPath: config, kimiCredentialsDir: creds)
        XCTAssertEqual(result.0, .unreadable)
    }

    // MARK: - g. CLI-driven refresh diagnostics (RefreshReport)

    /// A fake `kimi` ACP binary: answers initialize/session/new/
    /// session/prompt over NDJSON and optionally rewrites the grant file.
    private func fakeKimiCLI(credFile: String, rewrite: Bool) throws -> String {
        let script = """
        #!/usr/bin/python3
        import sys, json
        cred = "\(credFile)"
        rewrite = \(rewrite ? "True" : "False")
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                continue
            rid = req.get("id")
            if rid is None:
                continue
            method = req.get("method")
            if method == "initialize":
                result = {"protocolVersion": 1,
                          "serverInfo": {"name": "fake", "version": "0"}}
            elif method == "session/new":
                result = {"sessionId": "sess-1"}
            elif method == "session/prompt":
                if rewrite:
                    with open(cred, "w") as f:
                        f.write('{"access_token":"tok-refreshed",'
                                '"expires_at":4102444800}')
                result = {"stopReason": "end_turn"}
            else:
                result = {}
            sys.stdout.write(json.dumps(
                {"jsonrpc": "2.0", "id": rid, "result": result}) + "\\n")
            sys.stdout.flush()
        """
        let path = dir + "/fake-kimi-\(rewrite ? "rw" : "ro")"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// kimiProfile reads the canonical config; without a real Kimi install
    /// the end-to-end spawn test is skipped.
    private func requireKimiInstall() throws {
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.kimi-code/config.toml"),
            "no canonical Kimi config")
    }

    /// A stub CLI that answers ACP and rewrites the grant produces a fully
    /// populated RefreshReport, and the refresh sandbox profile grants
    /// write access to the credentials directory.
    func testKimiCLIRefreshReportFields() async throws {
        try requireKimiInstall()
        let (config, creds) = try kimiConfig()
        let grant = creds + "/test-grant.json"
        try #"{"access_token":"tok-old","expires_at":1000}"#
            .write(toFile: grant, atomically: true, encoding: .utf8)
        let binary = try fakeKimiCLI(credFile: grant, rewrite: true)
        let home = dir + "/krefresh-home"
        let paths = ProfileBuilder.Paths(
            home: home, devinBinary: "/bin/true",
            kimiBinary: binary, mcpBridge: "/bin/true")
        let lines = Recorder()
        let report = try await KimiCLIRefresh.run(
            kimiBinary: binary, paths: paths, credentialDir: creds,
            log: { line in lines.append(["l": .string(line)]) })
        XCTAssertTrue(report.spawned)
        XCTAssertTrue(report.initializeOK)
        XCTAssertTrue(report.sessionNewOK)
        XCTAssertEqual(report.promptStopReason, "end_turn")
        XCTAssertNil(report.promptError)
        XCTAssertNil(report.stepError)
        XCTAssertTrue(report.rewritten)
        XCTAssertNotNil(report.credentialMtimeBefore)
        XCTAssertNotNil(report.credentialMtimeAfter)
        XCTAssertGreaterThanOrEqual(report.durationMs, 0)
        let logged = lines.bodies.compactMap { $0["l"]?.stringValue }
        XCTAssertTrue(logged.contains { $0.contains("initialize") })
        XCTAssertTrue(logged.contains { $0.contains("session/prompt") })
        XCTAssertTrue(logged.contains { $0.contains("credentialRewritten=true") })
        // The refresh sandbox profile grants the credentials dir write and
        // spawns from a generation-shaped writer-runs cwd (spawn parity
        // with a native turn's writerSandboxProfile).
        let sb = try String(contentsOfFile: home
            + "/writer-runs/refresh-kimi/refresh.sb")
        XCTAssertTrue(sb.contains(ProfileBuilder.canonicalPath(creds)))
        XCTAssertTrue(sb.contains("allow file-write*"))
    }

    /// A stub that answers ACP but never rewrites the grant produces the
    /// exact "did not rewrite" Login-required error from readAccessToken.
    func testKimiRefreshStubNeverRewritesYieldsDidNotRewrite() async throws {
        try requireKimiInstall()
        let (config, creds) = try kimiConfig()
        let grant = creds + "/test-grant.json"
        try #"{"access_token":"tok-old","expires_at":1000}"#
            .write(toFile: grant, atomically: true, encoding: .utf8)
        let binary = try fakeKimiCLI(credFile: grant, rewrite: false)
        let home = dir + "/krefresh-home-ro"
        let paths = ProfileBuilder.Paths(
            home: home, devinBinary: "/bin/true",
            kimiBinary: binary, mcpBridge: "/bin/true")
        do {
            _ = try await KimiOAuthCredential.readAccessToken(
                configPath: config, credentialsDir: creds,
                kimiBinary: binary,
                refreshViaCLI: { bin in
                    try await KimiCLIRefresh.run(
                        kimiBinary: bin, paths: paths,
                        credentialDir: creds)
                })
            XCTFail("un-rewritten grant must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "Login required: Kimi CLI refresh did not rewrite the grant"),
                error.localizedDescription)
        }
    }

    /// A managed-shaped owner turn (LaneSelectingAdapter with native: nil,
    /// usesWorkspaceFilesystem via localTools) seals its writer generation
    /// and announces the candidate exactly like a native turn.
    func testManagedShapedOwnerTurnSealsGeneration() async throws {
        let root = NSTemporaryDirectory() + "managed-seal-"
            + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inner = FakeAdapter(engineer: .deepseek, delayPerDelta: .zero)
        inner.workspaceWrites = ["hello.txt": "workshop-phase2-ok"]
        let lane = LaneSelectingAdapter(engineer: .deepseek, native: nil,
                                        managed: inner) { _, _, _ in }
        let service = try CollaborationService(
            databasePath: root + "/db.sqlite", adapters: [lane],
            dispatcherEnabled: false, homeDir: root,
            wakeupCoalescence: .zero)
        inner.toolRunner = { name, args, principal in
            try await service.callTool(name, args: args,
                                       principal: principal) }
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "seal", title: "T",
            objective: "o", phase: .execution,
            participants: [.deepseek],
            collaborationMode: .requestedPeers))
        await service.start()
        let detail = try await service.getTask(receipt.taskID)
        let sub = detail.subtasks[0]
        _ = try await service.claimForTest(subtaskID: sub.id,
                                           owner: .deepseek,
                                           expectedGeneration: sub.generation)
        try await service.setTaskStateForTest(receipt.taskID, .working)
        inner.script = { context in
            guard let sub = context.subtask else {
                return [.text("no subtask")] }
            return [.toolCall("workshop_report_result", .object([
                "task_id": .string(context.task.id.rawValue),
                "subtask_id": .string(sub.id.rawValue),
                "summary": .string("phase2 smoke ok"),
                "generation": .number(Double(sub.generation)),
                "validation": .array([.object([
                    "check": .string("cat hello.txt"),
                    "result": .string("workshop-phase2-ok")])])])),
                .text("done")]
        }
        await service.runTurnForTest(engineer: .deepseek,
                                     taskID: receipt.taskID)
        let snapshot = try await service.writerSnapshotPath(
            taskID: receipt.taskID, engineer: .deepseek, sealedOnly: true)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(
            try String(contentsOfFile: (snapshot ?? "") + "/hello.txt"),
            "workshop-phase2-ok")
        let after = try await service.getTask(receipt.taskID)
        XCTAssertEqual(after.task.state, .verifying)
        await service.shutdown()
    }
}
