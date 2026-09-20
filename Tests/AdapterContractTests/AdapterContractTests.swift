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
        transport.inject(#"{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t1","title":"Calling workshop_post_message from workshop","rawInput":{},"_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}},"options":[{"optionId":"o1","name":"Approve once","kind":"allow_once"},{"optionId":"o2","name":"Reject","kind":"reject_once"}]}}"#)
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

    func testShellPermissionCannotBeGrantedByDisplayTitle() async throws {
        for title in ["Read harmless-looking command", "Run tests for workshop"] {
            let transport = FakeACPTransport(responder: happyResponder())
            let client = ACPClient(transport: transport)
            let request: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(97),
                "method": .string("session/request_permission"),
                "params": .object([
                    "sessionId": .string("s"),
                    "toolCall": .object(["toolCallId": .string("t"), "title": .string(title),
                        "rawInput": .object(["command": .string("unapproved command")]),
                        "_meta": .object(["cognition.ai/toolName": .string("exec")])]),
                    "options": .array([
                        .object(["optionId": .string("allow"), "kind": .string("allow_once"), "name": .string("Allow")]),
                        .object(["optionId": .string("deny"), "kind": .string("reject_once"), "name": .string("Reject")])])])])
            transport.inject(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
            try await Task.sleep(for: .milliseconds(100))
            let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 97 }
            XCTAssertEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "deny")
            await client.close()
        }
    }

    func testPermissionWithoutRejectOptionNeverSelectsAllow() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","id":96,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"t","title":"Unapproved execution","_meta":{"cognition.ai/toolName":"exec"}},"options":[{"optionId":"allow","kind":"allow_once","name":"Allow"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 96 }
        XCTAssertNotEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "allow")
        await client.close()
    }

    func testPermissionAllowAlwaysOnlyCancels() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","id":95,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"t","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}},"options":[{"optionId":"aa","kind":"allow_always","name":"Always allow"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 95 }
        XCTAssertEqual(response?["result"]?["outcome"]?["outcome"]?.stringValue, "cancelled")
        await client.close()
    }

    func testPermissionWithoutAnyRejectCancels() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","id":94,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"t","_meta":{"cognition.ai/toolName":"exec"}},"options":[{"optionId":"a","kind":"allow_once","name":"Allow"},{"optionId":"b","kind":"allow_always","name":"Always"}]}}"#)
        try await Task.sleep(for: .milliseconds(100))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 94 }
        XCTAssertEqual(response?["result"]?["outcome"]?["outcome"]?.stringValue, "cancelled")
        await client.close()
    }

    func testRememberedToolCallAuthorizesIDOnlyRequestPerSession() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"shared","title":"raw","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s2","update":{"sessionUpdate":"tool_call","toolCallId":"shared","title":"raw","_meta":{"cognition.ai/toolName":"exec"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":93,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"shared"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":92,"method":"session/request_permission","params":{"sessionId":"s2","toolCall":{"toolCallId":"shared"},"options":[{"optionId":"ok2","kind":"allow_once","name":"Allow"},{"optionId":"no2","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let allowed = transport.sentLines.map(json).last { $0["id"]?.intValue == 93 }
        let denied = transport.sentLines.map(json).last { $0["id"]?.intValue == 92 }
        XCTAssertEqual(allowed?["result"]?["outcome"]?["optionId"]?.stringValue, "ok")
        XCTAssertEqual(denied?["result"]?["outcome"]?["optionId"]?.stringValue, "no2")
        await client.close()
    }

    func testConflictingToolIdentityRejects() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"x","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":91,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"x","_meta":{"cognition.ai/toolName":"exec"}},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 91 }
        XCTAssertEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "no")
        await client.close()
    }

    func testRememberedRawInputUpdatedFullyForApprovalBoundary() async throws {
        let workspace = dir!
        let transport = FakeACPTransport(responder: happyResponder())
        let policy = ACPPermissionPolicy(workspace: workspace, approvedCommands: [
            ACPCommandApproval(command: "/usr/bin/true", cwd: workspace)])
        let client = ACPClient(transport: transport, permissionPolicy: policy)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"e","kind":"execute","_meta":{"cognition.ai/toolName":"exec"},"rawInput":{"command":"/usr/bin/true"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":90,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"e"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"e","rawInput":{"command":"/usr/bin/true; touch /private/tmp/pwned-fixture"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":89,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"e"},"options":[{"optionId":"ok9","kind":"allow_once","name":"Allow"},{"optionId":"no9","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(200))
        let approved = transport.sentLines.map(json).last { $0["id"]?.intValue == 90 }
        let mutated = transport.sentLines.map(json).last { $0["id"]?.intValue == 89 }
        XCTAssertEqual(approved?["result"]?["outcome"]?["optionId"]?.stringValue, "ok")
        XCTAssertEqual(mutated?["result"]?["outcome"]?["optionId"]?.stringValue, "no9")
        await client.close()
    }

    func testNativeIdentityMetadataSurvivesPermissionMetadata() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let policy = ACPPermissionPolicy(workspace: dir!, approvedCommands: [
            ACPCommandApproval(command: "/usr/bin/true", cwd: dir!)])
        let client = ACPClient(transport: transport, permissionPolicy: policy)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"native","kind":"execute","_meta":{"cognition.ai/inferenceToolName":"exec"},"rawInput":{"command":"/usr/bin/true"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":81,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"native","_meta":{"cognition.ai/editableCommand":"/usr/bin/true"}},"options":[{"optionId":"ok","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":82,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"native","rawInput":{"command":"unapproved"},"_meta":{"cognition.ai/editableCommand":"unapproved"}},"options":[{"optionId":"ok2","kind":"allow_once"},{"optionId":"no2","kind":"reject_once"}]}}"#)
        _ = try await client.call("initialize")
        let allowed = transport.sentLines.map(json).last { $0["id"]?.intValue == 81 }
        let denied = transport.sentLines.map(json).last { $0["id"]?.intValue == 82 }
        XCTAssertEqual(allowed?["result"]?["outcome"]?["optionId"]?.stringValue, "ok")
        XCTAssertEqual(denied?["result"]?["outcome"]?["optionId"]?.stringValue, "no2")
        await client.close()
    }

    func testPermissionDecisionEventIsNormalized() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        final class Box: @unchecked Sendable {
            var events: [ACPClient.ServerEvent] = []
            let lock = NSLock()
        }
        let box = Box()
        await client.setEventSink { event in
            box.lock.lock(); box.events.append(event); box.lock.unlock()
        }
        transport.inject(#"{"jsonrpc":"2.0","id":88,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"raw-call-id","title":"PRIVATE RAW TITLE","rawInput":{"command":"secret-fixture-command"},"_meta":{"cognition.ai/toolName":"exec"}},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow workspace"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        box.lock.lock()
        let events = box.events
        box.lock.unlock()
        guard let decision = events.compactMap({ event -> ACPPermissionDecision? in
            if case .permissionDecision(let d) = event { return d }
            return nil
        }).last else { return XCTFail("no permissionDecision event") }
        XCTAssertEqual(decision.tool, "exec")
        XCTAssertEqual(decision.operation, "execute")
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.callID?.count, 64)
        XCTAssertNotEqual(decision.callID, "raw-call-id")
        for event in events {
            let rendered = String(describing: event)
            XCTAssertFalse(rendered.contains("PRIVATE RAW TITLE"))
            XCTAssertFalse(rendered.contains("secret-fixture-command"))
            XCTAssertFalse(rendered.contains("Allow workspace"))
        }
        await client.close()
    }

    func testConflictingSessionUpdateDeniedForIDOnlyRequest() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"c","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"c","_meta":{"cognition.ai/toolName":"exec"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":87,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"c"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 87 }
        XCTAssertEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "no")
        await client.close()
    }

    func testNULInIdentityNeverResolvesFromCache() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"good","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"bad\u0000evil","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"}}}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":86,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"good"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        transport.inject(#"{"jsonrpc":"2.0","id":83,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"bad\u0000evil"},"options":[{"optionId":"ok3","kind":"allow_once","name":"Allow"},{"optionId":"no3","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let rejected = transport.sentLines.map(json).last { $0["id"]?.intValue == 83 }
        let allowed = transport.sentLines.map(json).last { $0["id"]?.intValue == 86 }
        XCTAssertEqual(allowed?["result"]?["outcome"]?["optionId"]?.stringValue, "ok")
        XCTAssertEqual(rejected?["result"]?["outcome"]?["optionId"]?.stringValue, "no3")
        await client.close()
    }

    func testOversizedRawInputMarksConflictAndIsNotCached() async throws {
        let transport = FakeACPTransport(responder: happyResponder())
        let client = ACPClient(transport: transport)
        let big = String(repeating: "x", count: 70 * 1024)
        transport.inject(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"big","_meta":{"cognition.ai/toolName":"mcp__workshop__workshop_post_message"},"rawInput":{"command":"BASE"}}}}"#)
        let encoded = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"big\",\"rawInput\":{\"command\":\"/usr/bin/true\",\"padding\":\"" + big + "\"}}}}"
        transport.inject(encoded)
        transport.inject(#"{"jsonrpc":"2.0","id":85,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"big"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 85 }
        XCTAssertEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "no")
        await client.close()
    }

    func testBoundedRawInputWithinLimitIsCached() async throws {
        let workspace = dir!
        let transport = FakeACPTransport(responder: happyResponder())
        let policy = ACPPermissionPolicy(workspace: workspace, approvedCommands: [
            ACPCommandApproval(command: "/usr/bin/true", cwd: workspace)])
        let client = ACPClient(transport: transport, permissionPolicy: policy)
        let pad = String(repeating: "y", count: 32 * 1024)
        transport.inject("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"ok-call\",\"kind\":\"execute\",\"_meta\":{\"cognition.ai/toolName\":\"exec\"},\"rawInput\":{\"command\":\"/usr/bin/true\",\"timeout\":\"" + pad + "\"}}}}")
        transport.inject(#"{"jsonrpc":"2.0","id":84,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"ok-call"},"options":[{"optionId":"ok","kind":"allow_once","name":"Allow"},{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 84 }
        XCTAssertEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "ok")
        await client.close()
    }

    func testNoRawDiagnosticFilesOrThoughtLeakage() async throws {
        let diag = dir! + "/diag"
        try FileManager.default.createDirectory(atPath: diag, withIntermediateDirectories: true)
        let oldDiag = getenv("WORKSHOP_DIAG_DIR").map { String(cString: $0) }
        setenv("WORKSHOP_DIAG_DIR", diag, 1)
        defer {
            if let oldDiag { setenv("WORKSHOP_DIAG_DIR", oldDiag, 1) }
            else { unsetenv("WORKSHOP_DIAG_DIR") }
        }
        let transport = FakeACPTransport(responder: happyResponder())
        let adapter = ACPHarnessAdapter(
            spec: spec(), transportFactory: { _, _ in transport })
        let ref = try await adapter.openTaskSession(binding: binding())
        let task = WorkshopTask(id: TaskID("task_x"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(), updatedAt: Date())
        let context = TurnContext(task: task, subtask: nil, recentMessages: [])
        transport.inject(#"{"jsonrpc":"2.0","id":77,"method":"session/request_permission","params":{"sessionId":"sess-1","toolCall":{"toolCallId":"d","title":"PRIVATE CANARY","_meta":{"cognition.ai/toolName":"exec"}},"options":[{"optionId":"no","kind":"reject_once","name":"Reject"}]}}"#)
        var events: [AdapterEvent] = []
        for try await e in adapter.sendTurn(ref: ref, turnID: "t1", context: context,
                                            deadline: Date().addingTimeInterval(5)) {
            events.append(e)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: diag)
        for name in ["permission-requests.log", "acp-updates-kimi.log",
                     "acp-prompt-result-kimi.log"] {
            XCTAssertFalse(files.contains(name), name)
        }
        XCTAssertFalse(events.contains(.messageDelta("HIDDEN_TEST_THOUGHT")))
        let response = transport.sentLines.map(json).last { $0["id"]?.intValue == 77 }
        XCTAssertEqual(response?["result"]?["outcome"]?["optionId"]?.stringValue, "no")
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
        let adapter = ACPHarnessAdapter(spec: spec(), transportFactory: { _, _ in transport })
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
            "Native session for kimi could not be loaded "
            + "(ACP remote error -32000: no session); "
            + "started a new session (no checkpoint available yet)")))
    }

    /// A session/load that never answers (sandboxed harness wedged mid-resume)
    /// must time out, close the stalled transport, and fall back to
    /// session/new on a respawned client.
    func testSessionLoadTimeoutFallsBackToNewOnFreshTransport() async throws {
        func encode(_ v: JSONValue) -> String {
            String(decoding: try! JSONEncoder().encode(v), as: UTF8.self)
        }
        let spawns = LockedCounter()
        let responder: @Sendable (String) -> [String] = { line in
            let msg = try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            let id = msg["id"] ?? .null
            switch msg["method"]?.stringValue {
            case "initialize":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{"protocolVersion":1}}"#]
            case "session/load":
                return []  // never answered — the wedged resume
            case "session/new":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{"sessionId":"fresh-after-timeout"}}"#]
            case "session/prompt":
                return [#"{"jsonrpc":"2.0","id":"# + encode(id)
                    + #","result":{"stopReason":"end_turn"}}"#]
            default:
                return []
            }
        }
        let adapter = ACPHarnessAdapter(
            spec: spec(), transportFactory: { _, _ in
                spawns.bump()
                return FakeACPTransport(responder: responder)
            }, sessionLoadTimeout: .milliseconds(150))
        let ref = try await adapter.openTaskSession(binding: binding(native: "wedged-1"))
        XCTAssertEqual(ref.nativeSessionID, "fresh-after-timeout")
        XCTAssertEqual(spawns.value, 2)  // stalled transport was closed + respawned
        let task = WorkshopTask(id: TaskID("task_x"), channel: "main", title: "T",
                                brief: "b", phase: .execution, state: .working,
                                budgetPolicyRef: nil, createdAt: Date(), updatedAt: Date())
        var events: [AdapterEvent] = []
        let stream = adapter.sendTurn(
            ref: ref, turnID: "t1",
            context: TurnContext(task: task, subtask: nil, recentMessages: []),
            deadline: Date().addingTimeInterval(5))
        for try await e in stream { events.append(e) }
        XCTAssertTrue(events.contains { e in
            if case .uncertain(let note) = e {
                return note.contains("could not be loaded")
            }
            return false
        })
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
        let adapter = ACPHarnessAdapter(
            spec: spec(injection: .devinProjectConfigFile, engineer: .devin),
            transportFactory: { _, _ in transport })
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
        let adapter = ACPHarnessAdapter(spec: spec()) { _, _ in
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

    private final class LockedCounter: @unchecked Sendable {
        private(set) var value = 0
        private let lock = NSLock()
        func bump() { lock.lock(); value += 1; lock.unlock() }
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

    /// The suffix cut must not leave a leading `tool` result whose assistant
    /// call was dropped — that makes the provider reject the next request.
    func testDeepSeekCompactionSkipsOrphanedToolSequence() async throws {
        let adapter = deepseek(responses: [], recorded: Recorder())
        adapter.checkpointSummary = nil
        func msg(_ role: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = ["role": .string(role),
                                        "content": .string("x")]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        // suffix(20) lands between the assistant call and its results:
        // kept starts on the orphaned tool result.
        var history = (0..<44).map { _ in msg("user") }
        history.append(msg("assistant", ["tool_calls": .array([
            .object(["id": .string("call_1")]),
            .object(["id": .string("call_2")])]), "content": .null]))
        history.append(msg("tool", ["tool_call_id": .string("call_1")]))
        history.append(msg("tool", ["tool_call_id": .string("call_2")]))
        history += (0..<18).map { _ in msg("user") }
        let (kept, didCompact) = await adapter.compactedHistory(
            history, taskID: TaskID("task_x"))
        XCTAssertTrue(didCompact)
        XCTAssertEqual(kept.first?["role"]?.stringValue, "system")
        XCTAssertEqual(kept.count, 19)
        XCTAssertEqual(kept[1]["role"]?.stringValue, "user",
                       "orphan tool results must be dropped")
        for m in kept { XCTAssertNotEqual(m["role"]?.stringValue, "tool") }

        // Boundary landing ON the assistant keeps it only when all its
        // results follow.
        var answered = (0..<45).map { _ in msg("user") }
        answered.append(msg("assistant", ["tool_calls": .array([
            .object(["id": .string("call_9")])]), "content": .null]))
        answered.append(msg("tool", ["tool_call_id": .string("call_9")]))
        answered += (0..<18).map { _ in msg("user") }
        let (kept2, _) = await adapter.compactedHistory(
            answered, taskID: TaskID("task_x"))
        XCTAssertEqual(kept2[1]["role"]?.stringValue, "assistant")
        XCTAssertEqual(kept2[2]["tool_call_id"]?.stringValue, "call_9")
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
}
