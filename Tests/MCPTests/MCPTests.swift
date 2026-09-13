import XCTest
@testable import WorkshopMCP
@testable import WorkshopIPC
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// MCP bridge tests: protocol pinning, tools/list, tools/call roundtrip through
/// a real in-process IPC server with token authentication.
final class MCPTests: XCTestCase {
    private var dir: String!
    private var server: IPCServer!
    private var service: CollaborationService!

    override func setUp() async throws {
        dir = NSTemporaryDirectory() + "m-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Token for kimi.
        let profile = dir + "/profiles/kimi"
        try FileManager.default.createDirectory(atPath: profile,
                                                withIntermediateDirectories: true)
        try "deadbeef".write(toFile: profile + "/token", atomically: true,
                             encoding: .utf8)
        service = try CollaborationService(
            databasePath: dir + "/db.sqlite",
            adapters: EngineerID.allCases.map { FakeAdapter(engineer: $0) },
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero)
        server = try IPCServer(socketPath: dir + "/s.sock")
        let svc = service!
        server.authenticator = { token in try await svc.authenticate(token: token) }
        server.handler = { method, params, principal in
            guard WorkshopToolCatalog.method(for: method) != nil else {
                throw WorkshopError.methodNotFound(method)
            }
            return try await svc.callTool(method, args: params ?? .object([:]),
                                          principal: principal)
        }
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func bridge(output: @escaping (String) -> Void,
                        caller: @escaping (String, JSONValue) async throws -> JSONValue)
        -> MCPBridge {
        MCPBridge(engineer: .kimi, toolCaller: caller, output: output)
    }

    private func outputs() -> (NSMutableArray, (String) -> Void) {
        let lines = NSMutableArray()
        return (lines, { line in lines.add(line) })
    }

    private func decode(_ line: Any) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self,
                                  from: Data((line as! String).utf8))
    }

    func testInitializePinsProtocolVersion() async {
        let (lines, out) = outputs()
        let b = bridge(output: out) { _, _ in .null }
        await b.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let r = decode(lines[0])
        XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
    }

    func testNotificationsIgnored() async {
        let (lines, out) = outputs()
        let b = bridge(output: out) { _, _ in .null }
        await b.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(lines.count, 0)
    }

    func testUnknownMethod() async {
        let (lines, out) = outputs()
        let b = bridge(output: out) { _, _ in .null }
        await b.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        let r = decode(lines[0])
        XCTAssertEqual(r["error"]?["code"]?.intValue, -32601)
    }

    func testToolsListContainsWorkshopTools() async {
        let (lines, out) = outputs()
        let b = bridge(output: out) { _, _ in .null }
        await b.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let r = decode(lines[0])
        let names = r["result"]?["tools"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("workshop_get_task"))
        XCTAssertTrue(names.contains("workshop_report_result"))
        XCTAssertTrue(names.contains("workshop_submit_proposal"))
        XCTAssertTrue(names.contains("workshop_submit_report"))
        XCTAssertTrue(names.contains("workshop_assign_subtask"))
        XCTAssertTrue(names.contains("workshop_escalate_task"))
        XCTAssertEqual(names.count, 17)
    }

    func testUnknownToolIsError() async {
        let (lines, out) = outputs()
        let b = bridge(output: out) { _, _ in .null }
        await b.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        let r = decode(lines[0])
        XCTAssertEqual(r["result"]?["isError"], .bool(true))
    }

    /// Full roundtrip: MCP bridge → UDS IPC → service with .engineer(.kimi).
    func testToolsCallRoundtripThroughDaemon() async throws {
        let client = WorkshopClient(socketPath: dir + "/s.sock")
        try await client.connect()
        _ = try await client.call(WorkshopProtocol.authenticate,
                                  params: .object(["token": .string("deadbeef")]))

        // Seed a task with kimi as participant (direct service call).
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: "mcp-1", title: "T", objective: "obj",
            phase: .execution, participants: [.kimi]))

        let (lines, out) = outputs()
        let b = bridge(output: out) { method, args in
            try await client.call(method, params: args)
        }
        await b.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"workshop_get_task","arguments":{"task_id":"\#(receipt.taskID.rawValue)"}}}"#)
        let r = decode(lines[0])
        XCTAssertEqual(r["result"]?["isError"], .bool(false))
        let text = r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains(receipt.taskID.rawValue))
        await client.disconnect()
    }

    /// Unauthenticated (no token) connections are .user — engineer-scoped tools
    /// that require a participant still work for .user reads; an engineer from a
    /// different task gets notAParticipant.
    func testEngineerNotParticipantRejected() async throws {
        // Authenticate as kimi, then ask about a task kimi is NOT in.
        let client = WorkshopClient(socketPath: dir + "/s.sock")
        try await client.connect()
        _ = try await client.call(WorkshopProtocol.authenticate,
                                  params: .object(["token": .string("deadbeef")]))
        let receipt = try await service.createTask(CreateTaskRequest(
            idempotencyKey: "mcp-2", title: "T2", objective: "obj",
            phase: .execution, participants: [.devin]))
        let (lines, out) = outputs()
        let b = bridge(output: out) { method, args in
            try await client.call(method, params: args)
        }
        await b.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workshop_get_task","arguments":{"task_id":"\#(receipt.taskID.rawValue)"}}}"#)
        let r = decode(lines[0])
        XCTAssertEqual(r["result"]?["isError"], .bool(true))
        let text = r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("-32003"))
        await client.disconnect()
    }
}
