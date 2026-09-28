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
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionID)","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"HIDDEN_TEST_THOUGHT"}}}}"#,
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

    func testCancelNotificationHasNoResponseID() async throws {
        let transport = FakeACPTransport(responder: { line in
            let message = try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            XCTAssertNil(message["id"])
            XCTAssertEqual(message["method"]?.stringValue, "session/cancel")
            return [] // Correct agents do not respond to a notification.
        })
        let client = ACPClient(transport: transport)
        try await client.notify("session/cancel", params: .object(["sessionId": .string("s")]))
        await client.close()
    }

    func testUnresponsiveCancelReturnsAndSessionCanReopen() async throws {
        let responder = happyResponder()
        let adapter = ACPHarnessAdapter(spec: spec(), transportFactory: { _, _ in
            FakeACPTransport(responder: { line in
                if line.contains("session/cancel") { return [] }
                return responder(line)
            })
        }, cancellationTimeout: .milliseconds(60))
        let ref = try await adapter.openTaskSession(binding: binding())
        let start = ContinuousClock.now
        let result = await adapter.cancelTurn(ref: ref, turnID: "missing-prompt")
        XCTAssertFalse(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let reopened = try await adapter.openTaskSession(binding: binding())
        XCTAssertEqual(reopened.nativeSessionID, "sess-1")
        _ = await adapter.cancelTurn(ref: reopened, turnID: "cleanup")
    }

    func testCallCorrelatesByID() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        let result = try await client.call("initialize")
        XCTAssertEqual(result["protocolVersion"]?.intValue, 1)
        await client.close()
    }

    func testSessionOpenTimeoutEndsUnresponsiveTransport() async throws {
        let transport = FakeACPTransport(responder: { _ in [] })
        let client = ACPClient(transport: transport)
        let started = ContinuousClock.now
        do {
            _ = try await client.call("session/new", timeout: .milliseconds(50))
            XCTFail("unresponsive session should time out")
        } catch ACPClient.ACPError.timeout(let method) {
            XCTAssertEqual(method, "session/new")
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testStreamMappingToAdapterEvents() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(), transportFactory: { _, _ in transport })
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
        XCTAssertFalse(events.contains(.messageDelta("HIDDEN_TEST_THOUGHT")))
        XCTAssertTrue(events.contains(.toolActivity(title: "workshop_ping", status: "started", callID: "t1")))
        XCTAssertTrue(events.contains(.toolActivity(title: "workshop_ping", status: "completed", callID: "t1")))
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

    func testPermissionDeniedWhenExecuteCapabilityRemoved() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        await client.setCapabilities(TurnCapabilityManifest(
            edit: true, execute: false, fetch: true))
        transport.inject(#"{"jsonrpc":"2.0","id":98,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t2","title":"Bash rm -rf /","kind":"execute","rawInput":{}},"options":[{"optionId":"a1","name":"Allow","kind":"allow_once"},{"optionId":"r1","name":"Reject","kind":"reject_once"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let reply = transport.sentLines.compactMap { l -> JSONValue? in
            let j = self.json(l)
            return j["id"]?.intValue == 98 ? j : nil
        }.last
        XCTAssertEqual(reply?["result"]?["outcome"]?["optionId"]?.stringValue, "r1")
        await client.close()
    }

    func testExecutePermissionAllowedByKindUnderWriterManifest() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let workspace = "/private/tmp/workshop/writer-runs/one/workspace"
        let client = ACPClient(transport: transport)
        func request(_ id: Int, command: String, cwd: String) -> String {
            let payload: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                "method": .string("session/request_permission"),
                "params": .object([
                    "toolCall": .object([
                        "title": .string("exec"),
                        "kind": .string("execute"),
                        "rawInput": .object(["command": .string(command),
                                              "workdir": .string(cwd)]),
                        "_meta": .object(["cognition.ai/toolName": .string("exec")]),
                    ]),
                    "options": .array([
                        .object(["optionId": .string("a"), "kind": .string("allow_once")]),
                        .object(["optionId": .string("r"), "kind": .string("reject_once")]),
                    ]),
                ]),
            ])
            return String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
        }
        // The sandbox, not the prompt, is the boundary: execute tools are
        // allowed by kind regardless of command text or cwd.
        transport.inject(request(201, command: "pytest -q", cwd: workspace))
        transport.inject(request(202, command: "rm -rf .", cwd: workspace))
        transport.inject(request(203, command: "pytest -q",
                                 cwd: "/private/tmp/elsewhere"))
        try await Task.sleep(for: .milliseconds(100))
        let replies = Dictionary(uniqueKeysWithValues: transport.sentLines.compactMap { line -> (Int64, String)? in
            let value = self.json(line)
            guard let id = value["id"]?.intValue,
                  let selected = value["result"]?["outcome"]?["optionId"]?.stringValue else { return nil }
            return (id, selected)
        })
        XCTAssertEqual(replies[201], "a")
        XCTAssertEqual(replies[202], "a")
        XCTAssertEqual(replies[203], "a")
        await client.close()
    }

    func testPermissionKindComesFromPriorToolCallWhenRequestHasOnlyID() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        await client.setCapabilities(TurnCapabilityManifest(
            edit: true, execute: false, fetch: true))
        let update: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string("session/update"),
            "params": .object(["update": .object([
                "sessionUpdate": .string("tool_call"), "toolCallId": .string("exec-1"),
                "title": .string("exec"), "kind": .string("execute"),
                "rawInput": .object(["command": .string("pytest -q")]),
            ])]),
        ])
        transport.inject(String(decoding: try JSONEncoder().encode(update), as: UTF8.self))
        transport.inject(#"{"jsonrpc":"2.0","id":204,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"exec-1"},"options":[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let reply = transport.sentLines.map(json).first { $0["id"]?.intValue == 204 }
        // execute is denied by the manifest → the reject option wins.
        XCTAssertEqual(reply?["result"]?["outcome"]?["optionId"]?.stringValue, "r")
        await client.close()
    }

    // MARK: - ACPPermissionPolicy.decide

    private func jreq(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    func testDecideDevinStyleExecuteAllowsAllowOnce() {
        let request = jreq(#"{"toolCall":{"toolCallId":"c1"},"options":[{"optionId":"a","kind":"allow_once","name":"Allow"},{"optionId":"r","kind":"reject_once","name":"Reject"}]}"#)
        let prior = jreq(#"{"toolCallId":"c1","kind":"execute","title":"pytest -q"}"#)
        XCTAssertEqual(
            ACPPermissionPolicy.decide(request: request, priorToolCall: prior,
                                       capabilities: .writer),
            .allow(optionID: .string("a")))
    }

    func testDecideKimiStylePrefersAllowOnceOverAllowAlways() {
        let request = jreq(#"{"toolCall":{"toolCallId":"c2","title":"Bash"},"options":[{"optionId":"approve_always","kind":"allow_always"},{"optionId":"approve_once","kind":"allow_once"},{"optionId":"reject","kind":"reject_once"}]}"#)
        let prior = jreq(#"{"toolCallId":"c2","kind":"execute"}"#)
        XCTAssertEqual(
            ACPPermissionPolicy.decide(request: request, priorToolCall: prior,
                                       capabilities: .writer),
            .allow(optionID: .string("approve_once")))
    }

    func testDecideUnknownKindAllows() {
        let request = jreq(#"{"toolCall":{"toolCallId":"c3","title":"FooBarTool"},"options":[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]}"#)
        XCTAssertEqual(
            ACPPermissionPolicy.decide(request: request, priorToolCall: nil,
                                       capabilities: .writer),
            .allow(optionID: .string("a")))
    }

    func testDecideRejectsScopeExpansion() {
        let request = jreq(#"{"toolCall":{"toolCallId":"c4","_meta":{"cognition.ai/toolName":"request_scope"}},"options":[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]}"#)
        XCTAssertEqual(
            ACPPermissionPolicy.decide(request: request, priorToolCall: nil,
                                       capabilities: .writer),
            .reject(optionID: .string("r")))
    }

    func testDecideCapabilityGatedKinds() {
        let options = #","options":[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]}"#
        for (kind, deniedManifest) in [
            ("edit", TurnCapabilityManifest(edit: false, execute: true, fetch: true)),
            ("execute", TurnCapabilityManifest(edit: true, execute: false, fetch: true)),
            ("fetch", TurnCapabilityManifest(edit: true, execute: true, fetch: false)),
        ] {
            let request = jreq(#"{"toolCall":{"kind":""# + kind + #""}"# + options)
            XCTAssertEqual(
                ACPPermissionPolicy.decide(request: request, priorToolCall: nil,
                                           capabilities: deniedManifest),
                .reject(optionID: .string("r")), kind)
            XCTAssertEqual(
                ACPPermissionPolicy.decide(request: request, priorToolCall: nil,
                                           capabilities: .writer),
                .allow(optionID: .string("a")), kind)
        }
    }

    func testDecideReadsInferenceToolName() {
        // Devin's native servers report the tool under
        // cognition.ai/inferenceToolName rather than toolName.
        let request = jreq(#"{"toolCall":{"toolCallId":"c5","_meta":{"cognition.ai/inferenceToolName":"request_scope"}},"options":[{"optionId":"a","kind":"allow_once"},{"optionId":"r","kind":"reject_once"}]}"#)
        XCTAssertEqual(
            ACPPermissionPolicy.decide(request: request, priorToolCall: nil,
                                       capabilities: .writer),
            .reject(optionID: .string("r")))
    }

    func testDecideNoAllowOption() {
        let request = jreq(#"{"toolCall":{"toolCallId":"c6"},"options":[{"optionId":"r","kind":"reject_once"}]}"#)
        XCTAssertEqual(
            ACPPermissionPolicy.decide(request: request, priorToolCall: nil,
                                       capabilities: .writer),
            .noOption)
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
        let adapter = ACPHarnessAdapter(spec: spec(engineer: .devin), transportFactory: { _, _ in transport })
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
            "Native session for devin could not be loaded "
            + "(ACP remote error -32000: no session); "
            + "started a new session (no checkpoint available yet)")))
    }

    func testKimiReusesNativeSessionInNewWriterGeneration() async throws {
        let responder = happyResponder(sessionID: "fresh-kimi")
        let transport = FakeACPTransport { line in
            let msg = self.json(line)
            if msg["method"]?.stringValue == "session/load" {
                let id = String(decoding: try! JSONEncoder().encode(msg["id"] ?? .null), as: UTF8.self)
                return [#"{"jsonrpc":"2.0","id":"# + id + #", "result":{}}"#]
            }
            return responder(line)
        }
        let adapter = ACPHarnessAdapter(spec: spec(engineer: .kimi),
                                        transportFactory: { _, _ in transport })
        let ref = try await adapter.openTaskSession(binding: binding(native: "old-workspace-session"))
        XCTAssertEqual(ref.nativeSessionID, "old-workspace-session")
        let methods = transport.sentLines.compactMap { self.json($0)["method"]?.stringValue }
        XCTAssertTrue(methods.contains("session/load"))
        XCTAssertFalse(methods.contains("session/new"))
    }

    func testKimiLoadTimeoutRestartsClientBeforeFreshSession() async throws {
        let first = FakeACPTransport { line in
            let msg = self.json(line)
            if msg["method"]?.stringValue == "session/load" { return [] }
            return self.happyResponder()(line)
        }
        let second = FakeACPTransport(responder: happyResponder(sessionID: "fallback-kimi"))
        var launches = 0
        let adapter = ACPHarnessAdapter(spec: spec(engineer: .kimi),
                                        transportFactory: { _, _ in
            launches += 1
            return launches == 1 ? first : second
        }, sessionLoadTimeout: .milliseconds(50))
        let ref = try await adapter.openTaskSession(binding: binding(native: "stale-kimi"))
        XCTAssertEqual(ref.nativeSessionID, "fallback-kimi")
        XCTAssertEqual(launches, 2)
        XCTAssertFalse(first.sentLines.contains { self.json($0)["method"]?.stringValue == "session/new" })
        XCTAssertTrue(second.sentLines.contains { self.json($0)["method"]?.stringValue == "session/new" })
    }

    func testKimiSessionNewCarriesMCPServers() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(injection: .acpSessionParam, engineer: .kimi),
            transportFactory: { _, _ in transport })
        _ = try await adapter.openTaskSession(binding: binding())
        let sessionNew = transport.sentLines
            .first { self.json($0)["method"]?.stringValue == "session/new" }
        let servers = json(sessionNew!)["params"]?["mcpServers"]?.arrayValue
        XCTAssertEqual(servers?.first?["name"]?.stringValue, "workshop")
        XCTAssertEqual(servers?.first?["command"]?.stringValue, dir + "/workshop-mcp")
    }

    func testDevinWritesProjectMCPConfig() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let path = dir + "/.devin/mcp_config.local.json"
        try FileManager.default.createDirectory(atPath: dir + "/.devin",
                                                withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"workshop":{"args":["stale-token"]}}}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        let expectedToken = dir + "/token-DEVIN"
        let adapter = ACPHarnessAdapter(
            spec: spec(injection: .devinProjectConfigFile, engineer: .devin),
            transportFactory: { _, _ in
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let config = try JSONDecoder().decode(JSONValue.self, from: data)
                guard config["mcpServers"]?["workshop"]?["args"]?.arrayValue?
                    .last?.stringValue == expectedToken else {
                    throw WorkshopError.invalidRequest("current MCP config missing before startup")
                }
                return transport
            })
        _ = try await adapter.openTaskSession(binding: binding())
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

    /// The version probe is advisory (G-D5): an executable whose --version
    /// fails still reports available so wakeups retry rather than drop.
    func testVersionProbeFailureIsAdvisory() async throws {
        var s = spec()
        s.executable = "/bin/echo"
        let adapter = ACPHarnessAdapter(spec: s) { _, _ in
            FakeACPTransport(responder: self.happyResponder())
        } versionProbe: { _ in nil }
        let probe = await adapter.probe()
        XCTAssertEqual(probe.health.kind, .available)
        XCTAssertTrue(probe.health.detail.contains("version unknown"))
        XCTAssertFalse(probe.tested)
    }

    func testProbeUntestedVersionReported() async throws {
        let adapter = ACPHarnessAdapter(spec: spec()) { _, _ in
            FakeACPTransport(responder: self.happyResponder())
        } versionProbe: { _ in "9.9.9" }
        let probe = await adapter.probe()
        XCTAssertEqual(probe.health.kind, .available)
        XCTAssertFalse(probe.tested)
        XCTAssertTrue(probe.health.detail.contains("UNTESTED"))
        XCTAssertTrue(probe.health.detail.contains("auth unverified"))
    }

    func testDiscussionTurnSetsDiscussionCapabilities() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(), transportFactory: { _, _ in transport })
        let ref = try await adapter.openTaskSession(binding: binding())
        let task = WorkshopTask(id: TaskID("task_x"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(), updatedAt: Date())
        let workspace = TaskWorkspace(taskID: task.id, path: dir + "/ws",
                                      state: "discussion")
        let context = TurnContext(task: task, subtask: nil, recentMessages: [],
                                  workspace: workspace, capabilities: .discussion)
        for try await _ in adapter.sendTurn(ref: ref, turnID: "t1", context: context,
                                            deadline: Date().addingTimeInterval(5)) {}
        let manifest = await adapter.currentCapabilities()
        XCTAssertEqual(manifest, .discussion)
    }

    func testDevinConfigAllowsRoutineTools() throws {
        let paths = ProfileBuilder.Paths(home: dir + "/home",
                                         devinBinary: "/bin/echo",
                                         kimiBinary: "/bin/echo",
                                         mcpBridge: dir + "/workshop-mcp")
        _ = try ProfileBuilder.devinSpec(paths: paths, worktree: dir + "/wt",
                                         model: "test-model")
        let data = try Data(contentsOf: URL(fileURLWithPath:
            dir + "/home/profiles/clean-v2/devin/config/devin/config.json"))
        let config = try JSONDecoder().decode(JSONValue.self, from: data)
        let allow = config["permissions"]?["allow"]?.arrayValue?
            .compactMap { $0.stringValue } ?? []
        XCTAssertEqual(Set(allow),
                       ["read", "grep", "glob", "exec", "edit", "mcp__workshop__*"])
        XCTAssertEqual(config["agent"]?["model"]?.stringValue, "test-model")
    }

    func testKimiRunsNeverAsk() throws {
        let paths = ProfileBuilder.Paths(home: dir + "/home",
                                         devinBinary: "/bin/echo",
                                         kimiBinary: "/bin/echo",
                                         mcpBridge: dir + "/workshop-mcp")
        let spec = try ProfileBuilder.kimiSpec(paths: paths, worktree: dir + "/wt")
        XCTAssertEqual(Array(spec.args.suffix(2)), ["--auto", "acp"])
    }

    func testSandboxProfileContainsWorktreeAllow() throws {
        let dest = dir + "/isolation.sb"
        try ProfileBuilder.devinSandboxProfile(workshopHome: dir + "/home",
                                               worktree: dir + "/worktrees/task_1",
                                               destination: dest)
        let text = try String(contentsOfFile: dest)
        let canonicalDir = ProfileBuilder.canonicalPath(dir!)
        XCTAssertTrue(text.contains(#"(subpath "\#(canonicalDir)/worktrees/task_1")"#))
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
        let hist = dir + "/sessions/clean-v2/task_x/main.json"
        let histText = try String(contentsOfFile: hist)
        XCTAssertFalse(histText.contains("reasoning_content"))
        XCTAssertTrue(histText.contains("done"))
    }

    private func emptyDeepSeekResponse(finishReason: String) -> JSONValue {
        .object([
            "choices": .array([.object([
                "finish_reason": .string(finishReason),
                "message": .object(["content": .string(""), "tool_calls": .null]),
            ])]),
            "usage": .object(["prompt_tokens": .number(100),
                              "completion_tokens": .number(4000)]),
        ])
    }

    func testDeepSeekRetriesReasoningOnlyLengthWithoutLosingContext() async throws {
        let recorded = Recorder()
        let adapter = deepseek(
            responses: [(200, emptyDeepSeekResponse(finishReason: "length")),
                        (200, finalResponse())], recorded: recorded)
        let events = try await collect(adapter)
        XCTAssertEqual(recorded.bodies.count, 2)
        XCTAssertEqual(recorded.bodies[0]["reasoning_effort"]?.stringValue, "max")
        XCTAssertEqual(recorded.bodies[1]["reasoning_effort"]?.stringValue, "none")
        XCTAssertEqual(recorded.bodies[1]["thinking"]?["type"]?.stringValue, "disabled")
        XCTAssertEqual(recorded.bodies[0]["messages"], recorded.bodies[1]["messages"])
        XCTAssertTrue(events.contains(.messageDelta("done")))
        XCTAssertTrue(events.contains(.turnCompleted))
        let history = try String(contentsOfFile: dir + "/sessions/clean-v2/task_x/main.json")
        XCTAssertTrue(history.contains("done"))
    }

    func testDeepSeekNeverCompletesOrPersistsEmptyResponse() async throws {
        let recorded = Recorder()
        let adapter = deepseek(
            responses: [(200, emptyDeepSeekResponse(finishReason: "length")),
                        (200, emptyDeepSeekResponse(finishReason: "length"))],
            recorded: recorded)
        let events = try await collect(adapter)
        XCTAssertEqual(recorded.bodies.count, 2)
        XCTAssertFalse(events.contains(.turnCompleted))
        XCTAssertTrue(events.contains { event in
            if case .uncertain(let detail) = event {
                return detail.contains("empty response (finish_reason: length)")
            }
            return false
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir + "/sessions/clean-v2/task_x/main.json"))
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

    /// Managed-history compaction (§6.3): >60 messages → checkpoint-derived
    /// summary + newest 20, no model call.
    func testDeepSeekHistoryCompaction() async throws {
        let adapter = deepseek(responses: [], recorded: Recorder())
        adapter.checkpointSummary = { _ in "objective: X; next: continue" }
        let history = (0..<70).map {
            JSONValue.object(["role": .string("user"),
                              "content": .string("m\($0)")])
        }
        let (kept, didCompact) = await adapter.compactedHistory(
            history, taskID: TaskID("task_x"))
        XCTAssertTrue(didCompact)
        XCTAssertEqual(kept.count, 21)
        XCTAssertEqual(kept[0]["role"]?.stringValue, "system")
        XCTAssertTrue(kept[0]["content"]?.stringValue?
            .contains("objective: X; next: continue") == true)
        XCTAssertEqual(kept[1]["content"]?.stringValue, "m50")

        // Small history: untouched.
        let (untouched, didCompact2) = await adapter.compactedHistory(
            Array(history.prefix(10)), taskID: TaskID("task_x"))
        XCTAssertFalse(didCompact2)
        XCTAssertEqual(untouched.count, 10)
    }

    func testDeepSeekCompactionDoesNotKeepOrphanToolResponse() async throws {
        let adapter = deepseek(responses: [], recorded: Recorder())
        var history = (0..<50).map {
            JSONValue.object(["role": .string("user"), "content": .string("old\($0)")])
        }
        history.append(.object(["role": .string("assistant"),
            "tool_calls": .array([.object(["id": .string("old-call")])])]))
        history.append(.object(["role": .string("tool"),
            "tool_call_id": .string("old-call"), "content": .string("old result")]))
        history += (0..<19).map {
            JSONValue.object(["role": .string("user"), "content": .string("new\($0)")])
        }
        let (kept, compacted) = await adapter.compactedHistory(history,
                                                              taskID: TaskID("task_x"))
        XCTAssertTrue(compacted)
        XCTAssertEqual(kept[1]["role"]?.stringValue, "user")
        XCTAssertEqual(kept[1]["content"]?.stringValue, "new0")
        XCTAssertFalse(kept.contains { $0["tool_call_id"]?.stringValue == "old-call" })
    }

    // MARK: - Native error preservation

    /// session/new remote errors must surface their message (e.g. a native
    /// team-settings timeout), not collapse into a generic adapter failure.
    func testSessionNewFailurePreservesNativeMessage() async throws {
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
            case "session/new":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","error":{"code":-32603,"message":"session/new failed: fetching team settings timed out after 10 seconds"}}"#]
            default:
                return []
            }
        }
        let adapter = ACPHarnessAdapter(spec: spec(), transportFactory: { _, _ in transport })
        do {
            _ = try await adapter.openTaskSession(binding: binding())
            XCTFail("session/new failure must throw")
        } catch {
            let detail = error.localizedDescription
            XCTAssertTrue(detail.contains("session/new"), detail)
            XCTAssertTrue(detail.contains("team settings timed out after 10 seconds"), detail)
        }
    }

    /// A session/new response without a sessionId reports the real defect, not
    /// a bare "adapter unavailable".
    func testSessionNewMissingIDIsDescriptive() async throws {
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
            case "session/new":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{}}"#]
            default:
                return []
            }
        }
        let adapter = ACPHarnessAdapter(spec: spec(), transportFactory: { _, _ in transport })
        do {
            _ = try await adapter.openTaskSession(binding: binding())
            XCTFail("missing sessionId must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no sessionId"),
                          error.localizedDescription)
        }
    }

    /// A failed initialize (e.g. the sandboxed launcher died) leaves no
    /// half-initialized client behind: the next open respawns the transport.
    func testInitializeFailureRespawnsTransport() async throws {
        func encode(_ v: JSONValue) -> String {
            String(decoding: try! JSONEncoder().encode(v), as: UTF8.self)
        }
        var spawned = 0
        var allowInitialize = false
        let adapter = ACPHarnessAdapter(spec: spec()) { _, _ in
            spawned += 1
            return FakeACPTransport { line in
                let msg = self.json(line)
                let id = msg["id"] ?? .null
                switch msg["method"]?.stringValue {
                case "initialize":
                    if allowInitialize {
                        return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                            + #","result":{"protocolVersion":1}}"#]
                    }
                    return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                        + #","error":{"code":-32603,"message":"spawn rejected by sandbox"}}"#]
                case "session/new":
                    return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                        + #","result":{"sessionId":"fresh-9"}}"#]
                default:
                    return []
                }
            }
        }
        do {
            _ = try await adapter.openTaskSession(binding: binding())
            XCTFail("initialize failure must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("initialize"),
                          error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("spawn rejected by sandbox"),
                          error.localizedDescription)
        }
        allowInitialize = true
        let ref = try await adapter.openTaskSession(binding: binding())
        XCTAssertEqual(ref.nativeSessionID, "fresh-9")
        XCTAssertEqual(spawned, 2)
    }

    func testTransientRelayStartupRetriesWithinSameOpen() async throws {
        var spawned = 0
        var transports: [FakeACPTransport] = []
        let adapter = ACPHarnessAdapter(spec: spec()) { _, _ in
            spawned += 1
            let fail = spawned == 1
            let transport = FakeACPTransport { line in
                let message = self.json(line)
                let id = message["id"] ?? .null
                let encodedID = String(decoding: try! JSONEncoder().encode(id), as: UTF8.self)
                switch message["method"]?.stringValue {
                case "initialize":
                    return [fail
                        ? "{\"jsonrpc\":\"2.0\",\"id\":\(encodedID),\"error\":{\"code\":-32603,\"message\":\"fusion-relay: timed out\"}}"
                        : "{\"jsonrpc\":\"2.0\",\"id\":\(encodedID),\"result\":{\"protocolVersion\":1}}"]
                case "session/load":
                    return ["{\"jsonrpc\":\"2.0\",\"id\":\(encodedID),\"result\":{}}"]
                default: return []
                }
            }
            transports.append(transport)
            return transport
        }
        var existing = binding()
        existing.nativeSessionID = "keep-existing-session"
        let ref = try await adapter.openTaskSession(binding: existing)
        XCTAssertEqual(ref.nativeSessionID, "keep-existing-session")
        XCTAssertEqual(spawned, 2)
        XCTAssertTrue(transports[0].terminated)
        XCTAssertFalse(transports.flatMap(\.sentLines).contains { $0.contains("session/new") })
    }

    func testTransientRelayStartupStopsAfterThreeAttempts() async throws {
        var transports: [FakeACPTransport] = []
        let adapter = ACPHarnessAdapter(spec: spec()) { _, _ in
            let transport = FakeACPTransport { line in
                let id = self.json(line)["id"] ?? .null
                let encodedID = String(decoding: try! JSONEncoder().encode(id), as: UTF8.self)
                return ["{\"jsonrpc\":\"2.0\",\"id\":\(encodedID),\"error\":{\"code\":-32603,\"message\":\"fusion-relay: timed out\"}}"]
            }
            transports.append(transport)
            return transport
        }
        do {
            _ = try await adapter.openTaskSession(binding: binding())
            XCTFail("repeated timeout must stop")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fusion-relay: timed out"))
        }
        XCTAssertEqual(transports.count, 3)
        XCTAssertTrue(transports.allSatisfy(\.terminated))
        XCTAssertFalse(transports.flatMap(\.sentLines).contains { $0.contains("session/prompt") })
    }

    // MARK: - DeepSeek model selection

    /// A stub verification response whose `model` field is the provider echo.
    private func verifyEcho(_ model: String) -> JSONValue {
        .object([
            "model": .string(model),
            "choices": .array([.object(["message": .object([
                "content": .string(""), "tool_calls": .null])])]),
            "usage": .object(["prompt_tokens": .number(1),
                              "completion_tokens": .number(1)]),
        ])
    }

    /// The configured model is sent on the wire and verified at session open;
    /// the provider echo becomes the effective model.
    func testDeepSeekConfiguredModelVerifiedAtSessionOpen() async throws {
        let recorded = Recorder()
        let adapter = DeepSeekAdapter(
            transport: StubHTTP(responses: [(200, verifyEcho("deepseek-v4-pro")),
                                            (200, finalResponse())],
                                recorded: recorded),
            sessionsDir: dir + "/sessions",
            endpoint: URL(string: "https://example.invalid/api")!,
            model: "deepseek-v4-pro",
            keyReader: { "sk-test" },
            toolExecutor: { _, _ in "{}" })
        // Before verification, the configured selection is reported.
        let probe = await adapter.probe()
        XCTAssertEqual(probe.effectiveModel, "deepseek-v4-pro")
        let ref = try await adapter.openTaskSession(binding: SessionBinding(
            taskID: TaskID("task_x"), engineerID: .deepseek, role: "owner",
            workerID: "main"))
        XCTAssertEqual(ref.nativeSessionID, "deepseek:task_x:main")
        // First request is the bounded verification ping carrying the model.
        XCTAssertEqual(recorded.bodies[0]["model"]?.stringValue, "deepseek-v4-pro")
        XCTAssertEqual(recorded.bodies[0]["max_tokens"]?.intValue, 1)
        // The real turn request carries the same configured model.
        _ = try await collect(adapter)
        XCTAssertEqual(recorded.bodies[1]["model"]?.stringValue, "deepseek-v4-pro")
        // modelSelection feeds session bindings / usage rows.
        XCTAssertEqual(adapter.modelSelection, "deepseek-v4-pro")
    }

    /// Default selection is the verified V4.1-Flash identifier.
    func testDeepSeekDefaultModelIsV41FlashAlias() async throws {
        let recorded = Recorder()
        let adapter = deepseek(responses: [(200, finalResponse())], recorded: recorded)
        _ = try await collect(adapter)
        XCTAssertEqual(recorded.bodies[0]["model"]?.stringValue, "deepseek-flash")
        XCTAssertEqual(adapter.modelSelection, "deepseek-flash")
    }

    /// An identifier the provider does not serve fails the session open with
    /// the provider's own message — before any real turn request runs.
    func testDeepSeekUnavailableModelRejectedBeforeTurn() async throws {
        let recorded = Recorder()
        let adapter = DeepSeekAdapter(
            transport: StubHTTP(responses: [(400, .object([
                "error": .object([
                    "message": .string("The supported API model names are deepseek-flash, deepseek-v4-pro, but you passed deepseek-v4.1.")])]))],
                                recorded: recorded),
            sessionsDir: dir + "/sessions",
            endpoint: URL(string: "https://example.invalid/api")!,
            model: "deepseek-v4.1",
            keyReader: { "sk-test" },
            toolExecutor: { _, _ in "{}" })
        do {
            _ = try await adapter.openTaskSession(binding: SessionBinding(
                taskID: TaskID("task_x"), engineerID: .deepseek, role: "owner",
                workerID: "main"))
            XCTFail("unavailable model must fail session open")
        } catch {
            let detail = error.localizedDescription
            XCTAssertTrue(detail.contains("deepseek-v4.1"), detail)
            XCTAssertTrue(detail.contains("supported API model names"), detail)
        }
        XCTAssertEqual(recorded.bodies.count, 1) // only the verification ping
    }

    /// A provider-side alias (configured name ≠ served name) is reported
    /// through the uncertain channel rather than silently accepted.
    func testDeepSeekAliasEchoReported() async throws {
        let recorded = Recorder()
        var alias = toolCallResponse()
        if case .object(var o) = alias {
            o["model"] = .string("deepseek-flash")
            alias = .object(o)
        }
        var final = finalResponse()
        if case .object(var o) = final {
            o["model"] = .string("deepseek-flash")
            final = .object(o)
        }
        let adapter = DeepSeekAdapter(
            transport: StubHTTP(responses: [(200, alias), (200, final)],
                                recorded: recorded),
            sessionsDir: dir + "/sessions",
            endpoint: URL(string: "https://example.invalid/api")!,
            model: "deepseek-chat",
            keyReader: { "sk-test" },
            toolExecutor: { _, _ in #"{"ok":true}"# })
        let events = try await collect(adapter)
        XCTAssertTrue(events.contains(.uncertain(
            "DeepSeek served model \"deepseek-flash\" for configured \"deepseek-chat\"")))
        XCTAssertEqual(adapter.modelSelection, "deepseek-flash")
    }

    // MARK: - MCP over Streamable HTTP (Phase 1a)

    /// Kimi: with spec.mcpURL set and a readable token, session/new carries the
    /// HTTP mcpServers variant with a Bearer Authorization header.
    func testKimiSessionNewUsesHTTPMCPWhenURLSet() async throws {
        var seenSessionNew: JSONValue?
        let adapter = ACPHarnessAdapter(
            spec: {
                var s = spec()
                s.mcpURL = "http://127.0.0.1:1/mcp"
                return s
            }(),
            transportFactory: { _, _ in
                FakeACPTransport(responder: { line in
                    let msg = self.json(line)
                    if msg["method"]?.stringValue == "session/new" {
                        seenSessionNew = msg["params"]
                    }
                    return self.happyResponder()(line)
                })
            })
        _ = try await adapter.openTaskSession(binding: binding())
        let servers = seenSessionNew?["mcpServers"]?.arrayValue
        XCTAssertEqual(servers?.count, 1)
        let w = servers?.first
        XCTAssertEqual(w?["type"]?.stringValue, "http")
        XCTAssertEqual(w?["name"]?.stringValue, "workshop")
        XCTAssertEqual(w?["url"]?.stringValue, "http://127.0.0.1:1/mcp")
        let header = w?["headers"]?.arrayValue?.first
        XCTAssertEqual(header?["name"]?.stringValue, "Authorization")
        XCTAssertEqual(header?["value"]?.stringValue, "Bearer tok")
        XCTAssertNil(w?["command"])
    }

    /// Devin: with spec.mcpURL set, openTaskSession writes the HTTP transport
    /// config into <cwd>/.devin/mcp_config.local.json (mode 0600).
    func testDevinProjectConfigUsesHTTPMCPWhenURLSet() async throws {
        var s = spec(injection: .devinProjectConfigFile, engineer: .devin)
        s.mcpURL = "http://127.0.0.1:1/mcp"
        let adapter = ACPHarnessAdapter(
            spec: s, transportFactory: { _, _ in
                FakeACPTransport(responder: self.happyResponder())
            })
        let devinBinding = SessionBinding(taskID: TaskID("task_x"),
                                          engineerID: .devin, role: "owner",
                                          workerID: "main")
        _ = try await adapter.openTaskSession(binding: devinBinding)
        let path = dir! + "/.devin/mcp_config.local.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let cfg = try JSONDecoder().decode(JSONValue.self, from: data)
        let w = cfg["mcpServers"]?["workshop"]
        XCTAssertEqual(w?["url"]?.stringValue, "http://127.0.0.1:1/mcp")
        XCTAssertEqual(w?["transport"]?.stringValue, "http")
        XCTAssertEqual(w?["headers"]?["Authorization"]?.stringValue, "Bearer tok")
        XCTAssertNil(w?["command"])
        let mode = try FileManager.default
            .attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
