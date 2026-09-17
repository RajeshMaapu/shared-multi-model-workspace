import XCTest
@testable import WorkshopMCP
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// Phase 5: Codex principal — limited authority, task-entry contract (§8.4),
/// idempotency through the bridge (T01/T02), forbidden actions -32005 (T27),
/// and the offline-bridge isError path (T35).
final class CodexBridgeTests: XCTestCase {
    private var dir: String!
    private var service: CollaborationService!

    override func setUp() async throws {
        dir = NSTemporaryDirectory() + "cx-\(UUID().uuidString.prefix(8))"
        let profile = dir! + "/profiles/codex"
        try FileManager.default.createDirectory(atPath: profile,
                                                withIntermediateDirectories: true)
        try "codex-token".write(toFile: profile + "/token", atomically: true,
                                encoding: .utf8)
        service = try CollaborationService(
            databasePath: dir + "/db.sqlite",
            adapters: EngineerID.allCases.map { FakeAdapter(engineer: $0) },
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private var codex: Principal { .codex }

    private func createArgs(key: String, title: String = "T",
                            objective: String = "obj") -> JSONValue {
        .object([
            "idempotency_key": .string(key),
            "title": .string(title),
            "objective": .string(objective),
            "phase": .string("execution"),
            "participants": .array([.string("deepseek")]),
        ])
    }

    func testCodexTokenAuthenticates() async throws {
        let p = try await service.authenticate(token: "codex-token")
        XCTAssertEqual(p, .codex)
        XCTAssertEqual(p.displayName, "You (via Codex)")
    }

    /// T01 through the tool surface: same key + same payload → same receipt.
    func testCreateTaskIdempotentDuplicate() async throws {
        let first = try await service.callTool(
            "workshop_create_task", args: createArgs(key: "codex-abc"),
            principal: codex)
        let second = try await service.callTool(
            "workshop_create_task", args: createArgs(key: "codex-abc"),
            principal: codex)
        XCTAssertEqual(first["task_id"]?.stringValue,
                       second["task_id"]?.stringValue)
        XCTAssertEqual(first["committed_seq"], second["committed_seq"])
        XCTAssertNotNil(first["state"]?.stringValue)
        XCTAssertTrue(["created", "queued", "running"]
            .contains(first["status"]?.stringValue ?? ""))
        // Scheme unverified in tests → truthful note, no link.
        XCTAssertEqual(first["deep_link"], .null)
        XCTAssertNotNil(first["deep_link_note"]?.stringValue)
        let tasks = try await service.listTasks()
        XCTAssertEqual(tasks.count, 1)
    }

    /// T01-via-Codex normalization: a codex key carrying the full 64-hex
    /// digest and the correct 32-hex form of the same hash map to one task.
    func testCreateTaskKeyNormalization() async throws {
        let hex64 = String(repeating: "0123456789abcdef", count: 4)
        let full = try await service.callTool(
            "workshop_create_task", args: createArgs(key: "codex-" + hex64),
            principal: codex)
        let short = try await service.callTool(
            "workshop_create_task",
            args: createArgs(key: "codex-" + String(hex64.prefix(32))),
            principal: codex)
        XCTAssertEqual(full["task_id"], short["task_id"])
        let tasks = try await service.listTasks()
        XCTAssertEqual(tasks.count, 1)
        // A key that does not match codex-<33-64 hex> is used verbatim.
        _ = try await service.callTool(
            "workshop_create_task",
            args: createArgs(key: "codex-" + hex64 + "ff"), // 66 hex → verbatim
            principal: codex)
        var count = try await service.listTasks().count
        XCTAssertEqual(count, 2)
        // User principal keys are never rewritten.
        _ = try await service.callTool(
            "workshop_create_task",
            args: createArgs(key: "codex-" + hex64),
            principal: .user)
        count = try await service.listTasks().count
        XCTAssertEqual(count, 3)
    }

    /// T02: same idempotency key, different payload → idempotency conflict.
    func testCreateTaskIdempotencyConflict() async throws {
        _ = try await service.callTool(
            "workshop_create_task", args: createArgs(key: "codex-dup"),
            principal: codex)
        do {
            _ = try await service.callTool(
                "workshop_create_task",
                args: createArgs(key: "codex-dup", title: "different"),
                principal: codex)
            XCTFail("expected idempotency conflict")
        } catch let error as WorkshopRPCError {
            XCTAssertEqual(error.rpcCode, -32009)
            XCTAssertTrue(error.message.contains("idempotency conflict"))
        }
    }

    /// Verified scheme → the receipt carries the workshop:// deep link.
    func testCreateTaskDeepLinkWhenRegistered() async throws {
        service.deepLinkHandlerVerified = true
        let r = try await service.callTool(
            "workshop_create_task", args: createArgs(key: "codex-dl"),
            principal: codex)
        XCTAssertEqual(r["deep_link"]?.stringValue,
                       "workshop://task/" + (r["task_id"]?.stringValue ?? ""))
    }

    /// T27: Codex cannot approve, accept, assign, or reassign (-32005).
    func testCodexForbiddenActions() async throws {
        for tool in ["workshop_assign_subtask", "workshop_propose_subtask",
                     "workshop_claim_subtask", "workshop_submit_proposal",
                     "workshop_submit_report", "workshop_publish_artifact",
                     "workshop_report_result"] {
            do {
                _ = try await service.callTool(tool, args: .object([:]),
                                               principal: codex)
                XCTFail("\(tool) must be refused for codex")
            } catch let error as WorkshopRPCError {
                XCTAssertEqual(error.rpcCode, -32005, tool)
            }
        }
        // An injected approval through the user-authority RPC path is refused
        // and changes nothing.
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: "codex-t27", title: "A", objective: "obj",
            phase: .researchProposal, participants: [.deepseek]))
        do {
            try await service.approveArchitecture(
                taskID: receipt.taskID, reportRevision: 1, scope: nil,
                principal: .codex)
            XCTFail("codex approval must be refused")
        } catch let error as WorkshopRPCError {
            XCTAssertEqual(error.rpcCode, -32005)
        }
        do {
            try await service.acceptTask(taskID: receipt.taskID,
                                         principal: .codex)
            XCTFail("codex accept must be refused")
        } catch let error as WorkshopRPCError {
            XCTAssertEqual(error.rpcCode, -32005)
        }
    }

    func testCodexRootMessageViaAndFollowUp() async throws {
        let r = try await service.callTool(
            "workshop_create_task", args: createArgs(key: "codex-root"),
            principal: codex)
        let taskID = TaskID(r["task_id"]!.stringValue!)
        let messages = try await service.readMessages(taskID)
        let root = try XCTUnwrap(messages.first { $0.seq == 1 })
        XCTAssertEqual(root.author, .user)
        let structured = root.structured
            .flatMap { try? JSONDecoder().decode(JSONValue.self,
                                                 from: Data($0.utf8)) }
        XCTAssertEqual(structured?["via"]?.stringValue, "codex")
        _ = try await service.callTool(
            "workshop_post_message",
            args: .object(["task_id": .string(taskID.rawValue),
                           "body": .string("follow-up body")]),
            principal: codex)
        let tasks = try await service.listTasks()
        XCTAssertEqual(tasks.count, 1)
        let after = try await service.readMessages(taskID)
        XCTAssertTrue(after.contains { $0.body == "follow-up body" })
    }

    /// Codex-posted messages: author user, via=codex in structured, wakes owner.
    func testCodexPostMessageVia() async throws {
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: "codex-msg", title: "M", objective: "obj",
            phase: .execution, participants: [.deepseek]))
        // Give the task an owner so a user message has someone to wake.
        let sub = try await service.getTask(receipt.taskID).subtasks[0]
        _ = try await service.claimForTest(subtaskID: sub.id, owner: .deepseek,
                                           expectedGeneration: 0)
        let result = try await service.callTool(
            "workshop_post_message",
            args: .object(["task_id": .string(receipt.taskID.rawValue),
                           "body": .string("follow-up")]),
            principal: codex)
        let messages = try await service.readMessages(receipt.taskID)
        let posted = messages.first { $0.body == "follow-up" }
        XCTAssertEqual(posted?.author, .user)
        let structured = posted?.structured
            .flatMap { try? JSONDecoder().decode(JSONValue.self,
                                                 from: Data($0.utf8)) }
        XCTAssertEqual(structured?["via"]?.stringValue, "codex")
        XCTAssertNotNil(result["seq"])
        // Owner wakeup queued exactly like a user message.
        let wakeups = try await service.wakeupsForTest(receipt.taskID)
        XCTAssertTrue(wakeups.contains { $0.engineerID == .deepseek })
    }

    /// T35 mechanism: when the daemon is unreachable the executable injects a
    /// failing toolCaller; every tools/call must return isError with the exact
    /// "service is not running" text while tools/list still answers.
    func testOfflineBridgeStillServesTools() async throws {
        struct Offline: WorkshopRPCError {
            var rpcCode: Int { -32000 }
            var message: String {
                "Workshop service is not running. Open Workshop.app (or start "
                    + "the background helper). Nothing was submitted."
            }
        }
        var lines: [String] = []
        let b = MCPBridge(engineer: .devin,
                          toolCaller: { _, _ in throw Offline() },
                          output: { lines.append($0) })
        await b.handle(line:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let list = try JSONDecoder().decode(JSONValue.self,
                                            from: Data(lines[0].utf8))
        XCTAssertFalse(list["result"]?["tools"]?.arrayValue?.isEmpty ?? true)
        await b.handle(line:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workshop_create_task","arguments":{"idempotency_key":"k","title":"t","objective":"o","phase":"execution"}}}"#)
        let r = try JSONDecoder().decode(JSONValue.self,
                                         from: Data(lines[1].utf8))
        XCTAssertEqual(r["result"]?["isError"], .bool(true))
        let text = r["result"]?["content"]?.arrayValue?
            .first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Workshop service is not running"))
        XCTAssertTrue(text.contains("Nothing was submitted"))
    }
}
