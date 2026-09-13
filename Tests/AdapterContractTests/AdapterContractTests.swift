import XCTest
@testable import WorkshopAdapters
@testable import WorkshopService
@testable import WorkshopCore

/// Deterministic adapter contract tests — all transports are fakes; no live
/// processes or network calls.
final class AdapterContractTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-adapter-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("WORKSHOP_MCP_PATH", dir! + "/workshop-mcp", 1)
        FileManager.default.createFile(atPath: dir! + "/workshop-mcp", contents: Data())
        for e in ["DEVIN", "KIMI", "DEEPSEEK"] {
            setenv("WORKSHOP_TOKEN_\(e)", dir! + "/token-\(e)", 1)
            FileManager.default.createFile(atPath: dir! + "/token-\(e)",
                                           contents: Data("tok".utf8))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Helpers

    private func json(_ line: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    private func requestID(_ line: String) -> JSONValue { json(line)["id"] ?? .null }

    /// Responder: initialize/session.new/prompt canned replies.
    private func happyResponder(sessionID: String = "sess-1") -> (String) -> [String] {
        { line in
            let msg = self.json(line)
            guard let method = msg["method"]?.stringValue else { return [] }
            let id = msg["id"] ?? .null
            func result(_ r: JSONValue) -> String {
                #"{"jsonrpc":"2.0","id":\#(String(decoding: try! JSONEncoder().encode(id), as: UTF8.self)),"result":\#(String(decoding: try! JSONEncoder().encode(r), as: UTF8.self))}"#
            }
            switch method {
            case "initialize":
                return [result(.object(["protocolVersion": .number(1)]))]
            case "session/new":
                return [result(.object(["sessionId": .string(sessionID)]))]
            case "session/prompt":
                return [
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionID)","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#,
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionID)","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"workshop_ping","rawInput":{}}}}"#,
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionID)","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","title":"workshop_ping"}}}"#,
                    result(.object([
                        "stopReason": .string("end_turn"),
                        "usage": .object([
                            "inputTokens": .number(100), "outputTokens": .number(20),
                            "cachedReadTokens": .number(50), "cachedWriteTokens": .null,
                            "totalTokens": .number(170)])])),
                ]
            default:
                return [result(.object([:]))]
            }
        }
    }

    private func spec(injection: MCPInjection = .acpSessionParam,
                      engineer: EngineerID = .kimi, cwd: String? = nil) -> HarnessLaunchSpec {
        HarnessLaunchSpec(engineer: engineer, executable: "/bin/echo", args: [],
                          env: [:], cwd: cwd ?? dir!,
                          mcpInjection: injection, qualifiedVersion: "0.0.0")
    }

    private func binding(native: String? = nil) -> SessionBinding {
        SessionBinding(taskID: TaskID("task_x"), engineerID: .kimi, role: "owner",
                       workerID: "main", nativeSessionID: native)
    }

    // MARK: - ACPClient

    func testCallCorrelatesByID() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        let result = try await client.call("initialize")
        XCTAssertEqual(result["protocolVersion"]?.intValue, 1)
        await client.close()
    }

    func testStreamMappingToAdapterEvents() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(), transportFactory: { _ in transport })
        let ref = try await adapter.openTaskSession(binding: binding())
        XCTAssertEqual(ref.nativeSessionID, "sess-1")
        let task = WorkshopTask(id: TaskID("task_x"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(), updatedAt: Date())
        let context = TurnContext(task: task, subtask: nil, recentMessages: [])
        var events: [AdapterEvent] = []
        for try await e in adapter.sendTurn(ref: ref, turnID: "t1", context: context,
                                            deadline: Date().addingTimeInterval(5)) {
            events.append(e)
        }
        XCTAssertTrue(events.contains(.messageDelta("Hello")))
        XCTAssertTrue(events.contains(.toolActivity(title: "workshop_ping", status: "started")))
        XCTAssertTrue(events.contains(.turnCompleted))
        let usage = events.first { if case .usageSample = $0 { return true }; return false }
        guard case .usageSample(let i, let o, let cr, let cw, let src)? = usage else {
            return XCTFail("no usage event")
        }
        XCTAssertEqual(i, 100); XCTAssertEqual(o, 20)
        XCTAssertEqual(cr, 50); XCTAssertNil(cw)
        XCTAssertEqual(src, "acp:kimi")
    }

    func testMalformedLinesAreSkipped() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject("not json at all")
        transport.inject(#"{"partial":"#)
        let result = try await client.call("initialize")
        XCTAssertNotNil(result)
        await client.close()
    }

    func testPermissionAllowOnceForWorkshopTool() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t1","title":"Calling workshop_ping from workshop","rawInput":{},"_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_ping"}},"options":[{"optionId":"o1","name":"Approve once","kind":"allow_once"},{"optionId":"o2","name":"Reject","kind":"reject_once"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let reply = transport.sentLines.compactMap { l -> JSONValue? in
            let j = self.json(l)
            return j["id"]?.intValue == 99 ? j : nil
        }.last
        XCTAssertEqual(reply?["result"]?["outcome"]?["outcome"]?.stringValue, "selected")
        XCTAssertEqual(reply?["result"]?["outcome"]?["optionId"]?.stringValue, "o1")
        await client.close()
    }

    func testPermissionRejectedForShellTool() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","id":98,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t2","title":"Bash rm -rf /","rawInput":{},"_meta":{"cognition.ai/toolName":"shell"}},"options":[{"optionId":"a1","name":"Allow","kind":"allow_once"},{"optionId":"r1","name":"Reject","kind":"reject_once"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let reply = transport.sentLines.compactMap { l -> JSONValue? in
            let j = self.json(l)
            return j["id"]?.intValue == 98 ? j : nil
        }.last
        XCTAssertEqual(reply?["result"]?["outcome"]?["optionId"]?.stringValue, "r1")
        await client.close()
    }

    // MARK: - ACPHarnessAdapter

    func testSessionLoadFailureFallsBackToNew() async throws {
        func encode(_ v: JSONValue) -> String {
            String(decoding: try! JSONEncoder().encode(v), as: UTF8.self)
        }
        let transport = FakeACPTransport { line in
            let msg = self.json(line)
            let id = msg["id"] ?? .null
            switch msg["method"]?.stringValue {
            case "initialize":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{"protocolVersion":1}}"#]
            case "session/load":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","error":{"code":-32000,"message":"no session"}}"#]
            case "session/new":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{"sessionId":"fresh-1"}}"#]
            case "session/prompt":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{"stopReason":"end_turn"}}"#]
            default:
                return []
            }
        }
        let adapter = ACPHarnessAdapter(spec: spec(), transportFactory: { _ in transport })
        let ref = try await adapter.openTaskSession(binding: binding(native: "stale-1"))
        XCTAssertEqual(ref.nativeSessionID, "fresh-1")
        // The fallback is surfaced as an .uncertain note at the start of the
        // next sendTurn stream (fix 3 — no longer silent).
        let task = WorkshopTask(id: TaskID("task_x"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(), updatedAt: Date())
        var events: [AdapterEvent] = []
        let stream = adapter.sendTurn(
            ref: ref, turnID: "t1",
            context: TurnContext(task: task, subtask: nil, recentMessages: []),
            deadline: Date().addingTimeInterval(5))
        for try await e in stream { events.append(e) }
        XCTAssertTrue(events.contains(.uncertain(
            "Native session for kimi could not be loaded; "
            + "started a new session (no checkpoint available yet)")))
    }

    func testKimiSessionNewCarriesMCPServers() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(injection: .acpSessionParam, engineer: .kimi),
            transportFactory: { _ in transport })
        _ = try await adapter.openTaskSession(binding: binding())
        let sessionNew = transport.sentLines
            .first { self.json($0)["method"]?.stringValue == "session/new" }
        let servers = json(sessionNew!)["params"]?["mcpServers"]?.arrayValue
        XCTAssertEqual(servers?.first?["name"]?.stringValue, "workshop")
        XCTAssertEqual(servers?.first?["command"]?.stringValue, dir + "/workshop-mcp")
    }

    func testDevinWritesProjectMCPConfig() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(injection: .devinProjectConfigFile, engineer: .devin),
            transportFactory: { _ in transport })
        _ = try await adapter.openTaskSession(binding: binding())
        let path = dir + "/.devin/mcp_config.local.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(JSONValue.self, from: data)
        let server = config["mcpServers"]?["workshop"]
        XCTAssertEqual(server?["command"]?.stringValue, dir + "/workshop-mcp")
        XCTAssertEqual(server?["transport"]?.stringValue, "stdio")
        // Devin must NOT get mcpServers in session/new.
        let sessionNew = transport.sentLines
            .first { self.json($0)["method"]?.stringValue == "session/new" }
        XCTAssertEqual(json(sessionNew!)["params"]?["mcpServers"]?.arrayValue?.count, 0)
    }

    func testProbeUnavailableForMissingBinary() async throws {
        var s = spec()
        s.executable = "/nonexistent/binary"
        let adapter = ACPHarnessAdapter(spec: s)
        let probe = await adapter.probe()
        XCTAssertEqual(probe.health.kind, .unavailable)
    }

    func testProbeUntestedVersionReported() async throws {
        let adapter = ACPHarnessAdapter(spec: spec()) { _ in
            FakeACPTransport(responder: self.happyResponder())
        } versionProbe: { _ in "9.9.9" }
        let probe = await adapter.probe()
        XCTAssertEqual(probe.health.kind, .available)
        XCTAssertFalse(probe.tested)
        XCTAssertTrue(probe.health.detail.contains("UNTESTED"))
        XCTAssertTrue(probe.health.detail.contains("auth unverified"))
    }

    func testSandboxProfileContainsWorktreeAllow() throws {
        let dest = dir + "/isolation.sb"
        try ProfileBuilder.devinSandboxProfile(workshopHome: dir + "/home",
                                               worktree: dir + "/worktrees/task_1",
                                               destination: dest)
        let text = try String(contentsOfFile: dest)
        XCTAssertTrue(text.contains(#"(subpath "\#(dir!)/worktrees/task_1")"#))
        XCTAssertTrue(text.contains(".local/share/devin/cli"))
        XCTAssertTrue(text.contains(#"(subpath "\#(NSHomeDirectory())/.claude")"#))
    }

    // MARK: - DeepSeek

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

    private func toolCallResponse() -> JSONValue {
        .object([
            "choices": .array([.object(["message": .object([
                "content": .null,
                "reasoning_content": .string("thinking about it"),
                "tool_calls": .array([.object([
                    "id": .string("call_1"),
                    "function": .object([
                        "name": .string("workshop_get_task"),
                        "arguments": .string(#"{"task_id":"task_x"}"#)])])])])])]),
            "usage": .object([
                "prompt_tokens": .number(300), "completion_tokens": .number(50),
                "prompt_cache_hit_tokens": .number(128),
                "prompt_cache_miss_tokens": .number(172)]),
        ])
    }

    private func finalResponse() -> JSONValue {
        .object([
            "choices": .array([.object(["message": .object([
                "content": .string("done"), "reasoning_content": .null,
                "tool_calls": .null])])]),
            "usage": .object([
                "prompt_tokens": .number(400), "completion_tokens": .number(3),
                "prompt_cache_hit_tokens": .number(0),
                "prompt_cache_miss_tokens": .number(400)]),
        ])
    }

    private func deepseek(
        responses: [(Int, JSONValue)],
        recorded: Recorder,
        tools: [String: String] = ["workshop_get_task": #"{"ok":true}"#]
    ) -> DeepSeekAdapter {
        DeepSeekAdapter(transport: StubHTTP(responses: responses, recorded: recorded),
                        sessionsDir: dir + "/sessions",
                        endpoint: URL(string: "https://example.invalid/api")!,
                        keyReader: { "sk-test" },
                        toolExecutor: { name, _ in tools[name] ?? #"{"error":"x"}"# })
    }

    private func collect(_ adapter: DeepSeekAdapter) async throws -> [AdapterEvent] {
        let ref = SessionRef(engineer: .deepseek,
                             nativeSessionID: "deepseek:task_x:main")
        let task = WorkshopTask(id: TaskID("task_x"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(), updatedAt: Date())
        var events: [AdapterEvent] = []
        let stream = adapter.sendTurn(ref: ref, turnID: "t",
                                      context: TurnContext(task: task, subtask: nil,
                                                           recentMessages: []),
                                      deadline: Date().addingTimeInterval(5))
        do {
            for try await e in stream { events.append(e) }
        } catch { events.append(.uncertain("threw")) }
        return events
    }

    func testDeepSeekToolLoopAndUsageMapping() async throws {
        let recorded = Recorder()
        let adapter = deepseek(responses: [(200, toolCallResponse()), (200, finalResponse())],
                               recorded: recorded)
        let events = try await collect(adapter)
        XCTAssertTrue(events.contains(.toolActivity(title: "workshop_get_task",
                                                    status: "calling")))
        XCTAssertTrue(events.contains(.messageDelta("done")))
        XCTAssertTrue(events.contains(.turnCompleted))
        // Usage: cache_read mapped from prompt_cache_hit_tokens; cache_write nil.
        let usages = events.compactMap { e -> (Int?, Int?, Int?, Int?, String)? in
            guard case .usageSample(let i, let o, let cr, let cw, let s) = e else { return nil }
            return (i, o, cr, cw, s)
        }
        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(usages[0].2, 128)
        XCTAssertNil(usages[0].3)
        XCTAssertEqual(usages[0].4, "deepseek:usage")
        // Second request: assistant message carries reasoning_content + tool_calls,
        // then a tool message.
        let second = recorded.bodies[1]
        let messages = second["messages"]?.arrayValue ?? []
        let assistant = messages.first {
            $0["role"]?.stringValue == "assistant" && $0["tool_calls"] != nil
        }
        XCTAssertEqual(assistant?["reasoning_content"]?.stringValue, "thinking about it")
        let tool = messages.first { $0["role"]?.stringValue == "tool" }
        XCTAssertEqual(tool?["tool_call_id"]?.stringValue, "call_1")
        XCTAssertEqual(tool?["content"]?.stringValue, #"{"ok":true}"#)
        // Session history persisted without reasoning_content.
        let hist = dir + "/sessions/task_x/main.json"
        let histText = try String(contentsOfFile: hist)
        XCTAssertFalse(histText.contains("reasoning_content"))
        XCTAssertTrue(histText.contains("done"))
    }

    func testDeepSeekAuthError() async throws {
        let recorded = Recorder()
        let adapter = deepseek(responses: [(401, .null)], recorded: recorded)
        let events = try await collect(adapter)
        XCTAssertTrue(events.contains(.authRequired))
    }

    func testDeepSeekQuotaError() async throws {
        let recorded = Recorder()
        let adapter = deepseek(responses: [(402, .null)], recorded: recorded)
        let events = try await collect(adapter)
        XCTAssertTrue(events.contains(.quotaLimited))
    }

    func testDeepSeekIterationCap() async throws {
        let recorded = Recorder()
        let adapter = deepseek(responses: [(200, toolCallResponse())], recorded: recorded)
        let events = try await collect(adapter)
        // 8 iterations all returning tool calls → stream ends with a throw.
        XCTAssertFalse(events.contains(.turnCompleted))
        XCTAssertEqual(recorded.bodies.count, 8)
    }

    func testCredentialScannerReadsKey() throws {
        let path = dir + "/config.toml"
        try """
        [providers.kimi]
        api_key = "kimi-key"

        [providers.deepseek]
        api_key = "ds-key-abc123"
        other = 1
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let key = try DeepSeekAdapter.readCredential(path: path,
                                                     section: "providers.deepseek",
                                                     key: "api_key")
        XCTAssertEqual(key, "ds-key-abc123")
    }
}
