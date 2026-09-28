import XCTest
@testable import WorkshopDaemonKit
@testable import WorkshopMCP
@testable import WorkshopService
@testable import WorkshopCore

/// Daemon-level MCP HTTP test: real DaemonRuntime with fake adapters, temp
/// WORKSHOP_HOME + runtime dir; the endpoint is exercised over loopback HTTP.
final class DaemonHTTPTests: XCTestCase {
    private var home = ""
    private var runtimeDir = ""
    private var runtime: DaemonRuntime?

    override func tearDown() async throws {
        if let runtime { await runtime.shutdown() }
        runtime = nil
        if !home.isEmpty { try? FileManager.default.removeItem(atPath: home) }
        if !runtimeDir.isEmpty {
            try? FileManager.default.removeItem(atPath: runtimeDir)
        }
    }

    private func post(_ url: String, body: String, token: String,
                      session: String? = nil) async throws
        -> (HTTPURLResponse, JSONValue?) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (resp as! HTTPURLResponse,
                try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    func testDaemonMCPEndpoint() async throws {
        home = NSTemporaryDirectory() + "wh-\(UUID().uuidString.prefix(8))"
        runtimeDir = NSTemporaryDirectory() + "wr-\(UUID().uuidString.prefix(8))"
        var env = ProcessInfo.processInfo.environment
        env["WORKSHOP_ADAPTERS"] = "fake"
        env["WORKSHOP_RUNTIME_DIR"] = runtimeDir
        let rt = try DaemonRuntime(home: home, runtimeDir: runtimeDir, env: env)
        runtime = rt
        try await rt.start()

        // mcp.json records the endpoint.
        let mcpInfo = try JSONDecoder().decode(JSONValue.self, from: Data(
            contentsOf: URL(fileURLWithPath: runtimeDir + "/mcp.json")))
        let url = mcpInfo["url"]?.stringValue ?? ""
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:"))
        XCTAssertEqual(mcpInfo["catalog_version"]?.intValue,
                       Int64(WorkshopToolCatalog.catalogVersion))

        let codexToken = try String(
            contentsOfFile: home + "/profiles/codex/token", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // initialize → session id.
        let (r1, j1) = try await post(url, body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            token: codexToken)
        XCTAssertEqual(r1.statusCode, 200)
        let sid = r1.value(forHTTPHeaderField: "Mcp-Session-Id")
        XCTAssertNotNil(sid)
        XCTAssertEqual(j1?["result"]?["serverInfo"]?["name"]?.stringValue,
                       "workshop-mcp")

        // tools/call workshop_list_tasks → real service result.
        let (r2, j2) = try await post(url, body:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workshop_list_tasks","arguments":{}}}"#,
            token: codexToken, session: sid)
        XCTAssertEqual(r2.statusCode, 200)
        XCTAssertEqual(j2?["result"]?["isError"], .bool(false))

        // Bogus token → 401.
        let (r3, _) = try await post(url, body:
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
            token: "bogus", session: sid)
        XCTAssertEqual(r3.statusCode, 401)

        // shutdown removes mcp.json.
        await rt.shutdown()
        runtime = nil
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtimeDir + "/mcp.json"))
    }
}
