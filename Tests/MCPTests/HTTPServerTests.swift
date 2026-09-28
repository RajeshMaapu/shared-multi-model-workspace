import XCTest
@testable import WorkshopMCP
@testable import WorkshopService
@testable import WorkshopCore

/// MCP Streamable HTTP server tests: auth, sessions, protocol negotiation,
/// SSE push, limits. Server runs on an ephemeral 127.0.0.1 port with fake
/// closures; requests use URLSession (POST/DELETE) or a raw socket (SSE GET).
final class HTTPServerTests: XCTestCase {
    private var server: MCPHTTPServer!
    private let token = "t0ken"
    private var revoked = false
    private var authorizeError: Error?
    private var callToolError: Error?
    private var calls: [(String, JSONValue, Principal)] = []

    override func setUp() async throws {
        revoked = false
        authorizeError = nil
        callToolError = nil
        calls = []
        var config = MCPHTTPServer.Config()
        config.keepaliveSeconds = 0.05
        server = MCPHTTPServer(
            config: config, serverVersion: "9",
            authenticate: { [self] t in
                // "bogus" is the only invalid token; anything else maps to
                // kimi so a different valid token exercises the session's
                // tokenHash binding (→ 404, not 401).
                if self.revoked || t == "bogus" {
                    throw WorkshopError.invalidRequest("invalid token")
                }
                return Principal.engineer(.kimi)
            },
            authorize: { [self] _, _, _ in
                if let e = self.authorizeError { throw e }
            },
            callTool: { [self] name, args, principal in
                self.calls.append((name, args, principal))
                if let e = self.callToolError { throw e }
                return .object(["ok": .bool(true)])
            })
        try server.start()
    }

    override func tearDown() {
        server?.stop()
    }

    // MARK: - Helpers

    private func post(_ body: String, token: String? = nil,
                      session: String? = nil, headers: [String: String] = [:])
        async throws -> (HTTPURLResponse, JSONValue?) {
        var req = URLRequest(url: URL(string: server.url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token ?? self.token)",
                     forHTTPHeaderField: "Authorization")
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        return (http, json)
    }

    private func initialize(version: String = "2025-06-18",
                            token: String? = nil) async throws
        -> (HTTPURLResponse, JSONValue?, String?) {
        let (resp, json) = try await post(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)"}}"#,
            token: token ?? self.token)
        return (resp, json, resp.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }

    private func rawRequest(_ text: String) throws -> Int32 {
        let port = server.boundPort
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        var sent = 0
        let bytes = Array(text.utf8)
        while sent < bytes.count {
            sent += bytes.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
        }
        return fd
    }

    private func readAvailable(_ fd: Int32, timeout: TimeInterval) -> String {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            let r = poll(&fds, 1, 200)
            if r <= 0 { continue }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if String(decoding: out, as: UTF8.self).contains("list_changed") { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Cases

    func testInitializeNegotiatesVersion() async throws {
        var (resp, json, sid) = try await initialize(version: "2025-11-25")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertNotNil(sid)
        XCTAssertEqual(json?["result"]?["protocolVersion"]?.stringValue, "2025-11-25")
        XCTAssertTrue(json?["result"]?["serverInfo"]?["version"]?.stringValue?
                        .contains("+catalog2") ?? false)
        (_, json, sid) = try await initialize(version: "2099-01-01")
        XCTAssertEqual(json?["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertNotNil(sid)
    }

    /// A successful initialize logs one client-session line with the
    /// negotiated protocol and clientInfo (never tokens or headers).
    func testInitializeLogsClientSession() async throws {
        var logged: [String] = []
        server.logger = { logged.append($0) }
        let (resp, _) = try await post(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"rmcp","version":"0.9.1"}}}"#)
        XCTAssertEqual(resp.statusCode, 200)
        let sid8 = String((resp.value(forHTTPHeaderField: "Mcp-Session-Id") ?? "")
            .prefix(8))
        let line = logged.first { $0.contains("mcp client session") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains(sid8) ?? false)
        XCTAssertTrue(line?.contains("principal=Kimi K3") ?? false)
        XCTAssertTrue(line?.contains("client=rmcp/0.9.1") ?? false)
        XCTAssertTrue(line?.contains("protocol=2025-06-18") ?? false)
        XCTAssertFalse(line?.contains("Bearer") ?? true)
    }

    func testAuthFailures() async throws {
        var req = URLRequest(url: URL(string: server.url)!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 401)
        XCTAssertNotNil((resp as! HTTPURLResponse)
            .value(forHTTPHeaderField: "WWW-Authenticate"))

        let (r2, _, _) = try await initialize(token: "bogus")
        XCTAssertEqual(r2.statusCode, 401)
    }

    func testSessionRequired() async throws {
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        var (resp, _) = try await post(list)
        XCTAssertEqual(resp.statusCode, 400)
        (resp, _) = try await post(list, session: "nosuchsession")
        XCTAssertEqual(resp.statusCode, 404)
    }

    func testNotificationReturns202() async throws {
        let (_, _, sid) = try await initialize()
        let (resp, json) = try await post(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            session: sid)
        XCTAssertEqual(resp.statusCode, 202)
        XCTAssertNil(json)
    }

    func testToolsList() async throws {
        var logged: [String] = []
        server.logger = { logged.append($0) }
        let (_, _, sid) = try await initialize()
        let (resp, json) = try await post(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, session: sid)
        XCTAssertEqual(resp.statusCode, 200)
        let tools = json?["result"]?["tools"]?.arrayValue
        XCTAssertEqual(tools?.count, WorkshopToolCatalog.tools.count)
        XCTAssertEqual(json?["result"]?["_meta"]?["workshop_catalog_version"]?.intValue, 2)
        // Catalog 2: workshop_read_messages accepts include_summaries.
        let readSchema = tools?.first {
            $0["name"]?.stringValue == "workshop_read_messages" }
        XCTAssertEqual(readSchema?["inputSchema"]?["properties"]?["include_summaries"]?["type"]?.stringValue, "boolean")
        // A-5: the call is logged with principal + count, no payload.
        let line = logged.first { $0.contains("mcp list") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("tools=\(WorkshopToolCatalog.tools.count)") ?? false)
        XCTAssertTrue(line?.contains("principal=") ?? false)
    }

    func testToolsCall() async throws {
        var logged: [String] = []
        server.logger = { logged.append($0) }
        let (_, _, sid) = try await initialize()
        let (resp, json) = try await post(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"workshop_list_tasks","arguments":{"a":1}}}"#,
            session: sid)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "workshop_list_tasks")
        XCTAssertEqual(calls[0].2, .engineer(.kimi))
        XCTAssertEqual(json?["result"]?["isError"], .bool(false))
        XCTAssertNotNil(json?["result"]?["_meta"])
        let text = json?["result"]?["content"]?.arrayValue?
            .first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("ok"))

        callToolError = WorkshopError.methodNotFound("nope")
        let (_, json2) = try await post(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"workshop_list_tasks","arguments":{}}}"#,
            session: sid)
        XCTAssertEqual(json2?["result"]?["isError"], .bool(true))
        let text2 = json2?["result"]?["content"]?.arrayValue?
            .first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text2.contains("\(WorkshopError.methodNotFound("x").rpcCode)"))
        // A-5: per-call log lines carry tool name + ok|error, no arguments.
        let callLines = logged.filter { $0.contains("mcp call") }
        XCTAssertEqual(callLines.count, 2)
        XCTAssertTrue(callLines[0].contains("tool=workshop_list_tasks ok"))
        XCTAssertTrue(callLines[1].contains("tool=workshop_list_tasks error"))
        XCTAssertTrue(callLines.allSatisfy { $0.contains("principal=") })
    }

    func testAuthorizeFailureIsToolError() async throws {
        authorizeError = WorkshopError.invalidRequest("Writer capability expired")
        let (_, _, sid) = try await initialize()
        let (resp, json) = try await post(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workshop_list_tasks","arguments":{}}}"#,
            session: sid)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(json?["result"]?["isError"], .bool(true))
        let text = json?["result"]?["content"]?.arrayValue?
            .first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Writer capability expired"))
    }

    func testPerRequestAuthAndTokenBinding() async throws {
        let (_, _, sid) = try await initialize()
        var (resp, _) = try await post(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"workshop_list_tasks","arguments":{}}}"#,
            session: sid)
        XCTAssertEqual(resp.statusCode, 200)
        revoked = true
        (resp, _) = try await post(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"workshop_list_tasks","arguments":{}}}"#,
            session: sid)
        XCTAssertEqual(resp.statusCode, 401)
        // A different valid token on the same session id → 404.
        revoked = false
        let altToken = "other" + "-valid" + "-token"
        (resp, _) = try await post(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
            token: altToken, session: sid)
        XCTAssertEqual(resp.statusCode, 404)
    }

    /// A DELETE on the session ends its SSE stream promptly even though
    /// keepalives are infrequent in production (default 15 s).
    func testDeleteEndsSSEStreamPromptly() async throws {
        var config = MCPHTTPServer.Config()
        config.keepaliveSeconds = 60 // worst case: must not delay stream close
        let token = self.token
        let extra = MCPHTTPServer(
            config: config, serverVersion: "9",
            authenticate: { t in
                guard t == token else {
                    throw WorkshopError.invalidRequest("invalid token")
                }
                return Principal.engineer(.kimi)
            },
            authorize: { _, _, _ in },
            callTool: { _, _, _ in .object([:]) })
        try extra.start()
        defer { extra.stop() }
        var req = URLRequest(url: URL(string: extra.url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (_, initResp) = try await URLSession.shared.data(for: req)
        let sid = (initResp as! HTTPURLResponse)
            .value(forHTTPHeaderField: "Mcp-Session-Id")!
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = extra.boundPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let get = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(token)\r\nAccept: text/event-stream\r\n"
            + "Mcp-Session-Id: \(sid)\r\n\r\n"
        _ = get.utf8.withContiguousStorageIfAvailable { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
        _ = readAvailable(fd, timeout: 2)
        var del = URLRequest(url: URL(string: extra.url)!)
        del.httpMethod = "DELETE"
        del.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        del.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        let start = Date()
        _ = try await URLSession.shared.data(for: del)
        // EOF on the stream socket within 3 s.
        var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&fds, 1, 3000), 1)
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        XCTAssertEqual(n, 0, "expected EOF on the SSE socket after DELETE")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testDeleteRemovesSession() async throws {
        let (_, _, sid) = try await initialize()
        var req = URLRequest(url: URL(string: server.url)!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
        let (resp2, _) = try await post(
            #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#, session: sid)
        XCTAssertEqual(resp2.statusCode, 404)
    }

    func testSSEStreamReceivesListChanged() async throws {
        let (_, _, sid) = try await initialize()
        let fd = try rawRequest(
            "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Authorization: Bearer \(token)\r\n"
                + "Accept: text/event-stream\r\n"
                + "Mcp-Session-Id: \(sid!)\r\n\r\n")
        defer { Darwin.close(fd) }
        let head = readAvailable(fd, timeout: 2)
        XCTAssertTrue(head.contains("200 OK"))
        XCTAssertTrue(head.contains("Content-Type: text/event-stream"))
        server.pushToolsListChanged()
        let body = readAvailable(fd, timeout: 5)
        XCTAssertTrue(body.contains("notifications/tools/list_changed"))
    }

    func testOriginCheck() async throws {
        let (resp, _) = try await post(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
            headers: ["Origin": "http://evil.example"])
        XCTAssertEqual(resp.statusCode, 403)
        let (resp2, _, sid) = try await initialize()
        _ = sid
        let ok = try await post(
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            session: sid, headers: ["Origin": "http://localhost:1234"])
        XCTAssertEqual(ok.0.statusCode, 200)
    }

    func testLimitsAndPaths() async throws {
        // 4 MiB + 1 body → 413.
        var big = URLRequest(url: URL(string: server.url)!)
        big.httpMethod = "POST"
        big.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        big.httpBody = Data(repeating: 0x61, count: 4 * 1024 * 1024 + 1)
        let (_, r413) = try await URLSession.shared.data(for: big)
        XCTAssertEqual((r413 as! HTTPURLResponse).statusCode, 413)

        let (rBatch, _) = try await post(#"[]"#)
        XCTAssertEqual(rBatch.statusCode, 400)

        // GET without SSE accept → 405 (valid session).
        let (_, _, sid) = try await initialize()
        var get = URLRequest(url: URL(string: server.url)!)
        get.httpMethod = "GET"
        get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        get.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        let (_, r405) = try await URLSession.shared.data(for: get)
        XCTAssertEqual((r405 as! HTTPURLResponse).statusCode, 405)

        var other = URLRequest(url: URL(string:
            server.url.replacingOccurrences(of: "/mcp", with: "/other"))!)
        other.httpMethod = "POST"
        other.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        other.httpBody = Data(#"{}"#.utf8)
        let (_, r404) = try await URLSession.shared.data(for: other)
        XCTAssertEqual((r404 as! HTTPURLResponse).statusCode, 404)
    }
}
