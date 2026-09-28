import CryptoKit
import Foundation
import Security
import WorkshopCore
import WorkshopService

/// MCP Streamable HTTP endpoint on 127.0.0.1 (spec 2025-03-26/2025-06-18
/// single-response mode). Hand-rolled HTTP/1.1 over POSIX sockets, one thread
/// per accepted connection. Bearer auth on every request; sessions are
/// in-memory only — a daemon restart invalidates them and clients re-initialize.
public final class MCPHTTPServer: @unchecked Sendable {
    public struct Config: Sendable {
        public var port: UInt16 = 0            // 0 = ephemeral
        public var maxBodyBytes = 4 * 1024 * 1024
        public var maxHeaderBytes = 64 * 1024
        public var maxSessions = 256
        public var maxStreams = 64
        public var sessionIdleSeconds: TimeInterval = 86_400
        public var keepaliveSeconds: TimeInterval = 15
        public var readTimeoutSeconds: TimeInterval = 30
        public init() {}
    }

    public enum HTTPError: Error, Equatable {
        case socketFailed(String)
    }

    private struct Session {
        var id: String
        var tokenHash: String
        var protocolVersion: String
        var lastSeen: Date
        var streamFD: Int32?
    }

    private let config: Config
    private let serverVersion: String
    private let authenticate: @Sendable (String) async throws -> Principal
    private let authorize: @Sendable (String, String, JSONValue?) async throws -> Void
    private let callTool: @Sendable (String, JSONValue, Principal) async throws -> JSONValue

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var streamFDs: Set<Int32> = []
    private var clientFDs: Set<Int32> = []

    public private(set) var boundPort: UInt16 = 0

    /// One line per client session lifecycle event (never tokens or headers).
    public var logger: (@Sendable (String) -> Void)?

    public var url: String { "http://127.0.0.1:\(boundPort)/mcp" }

    public init(config: Config, serverVersion: String,
                authenticate: @escaping @Sendable (String) async throws -> Principal,
                authorize: @escaping @Sendable (String, String, JSONValue?) async throws -> Void,
                callTool: @escaping @Sendable (String, JSONValue, Principal) async throws -> JSONValue) {
        self.config = config
        self.serverVersion = serverVersion
        self.authenticate = authenticate
        self.authorize = authorize
        self.callTool = callTool
    }

    /// socket + bind(127.0.0.1) + listen; sets boundPort; no accept thread yet.
    public func bind() throws {
        guard listenFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HTTPError.socketFailed("socket: \(String(cString: strerror(errno)))")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = config.port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw HTTPError.socketFailed(
                "bind 127.0.0.1:\(config.port): \(err)")
        }
        guard listen(fd, 16) == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw HTTPError.socketFailed("listen on port \(config.port): \(err)")
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(fd, sa, &len)
            }
        }
        listenFD = fd
        boundPort = UInt16(bigEndian: actual.sin_port)
    }

    /// Starts the accept thread (calls bind() first if not bound).
    public func start() throws {
        try bind()
        guard !running else { return }
        running = true
        acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread?.start()
    }

    public func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        lock.lock()
        // Connection threads own close() on their fd; shutdown unblocks reads
        // and fails in-flight writes so they exit and close it themselves.
        for fd in clientFDs { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    /// Write `notifications/tools/list_changed` to every open SSE stream.
    public func pushToolsListChanged() {
        let payload = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n"
        lock.lock()
        let targets = Array(streamFDs)
        lock.unlock()
        var failed: [Int32] = []
        for fd in targets where !writeAll(fd, payload) {
            failed.append(fd)
        }
        guard !failed.isEmpty else { return }
        lock.lock()
        for fd in failed {
            streamFDs.remove(fd)
            for id in sessions.keys where sessions[id]?.streamFD == fd {
                sessions[id]?.streamFD = nil
            }
            shutdownIfLive(fd)
        }
        lock.unlock()
    }

    /// shutdown() only while holding `lock` and only when the fd is still a
    /// live client connection — after the owning thread closes it the number
    /// can be reused by a new accept and must never be touched.
    private func shutdownIfLive(_ fd: Int32) {
        if clientFDs.contains(fd) { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: - Accept / connection handling

    private func acceptLoop() {
        while running {
            var peer = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(listenFD, &peer, &len)
            if fd < 0 { if running { continue } else { break } }
            var tv = timeval(
                tv_sec: Int(config.readTimeoutSeconds),
                tv_usec: Int32((config.readTimeoutSeconds
                                - TimeInterval(Int(config.readTimeoutSeconds))) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            clientFDs.insert(fd)
            lock.unlock()
            Thread { [weak self] in self?.serveConnection(fd) }.start()
        }
    }

    /// Owning-thread cleanup: unregister everything and close under the lock so
    /// no other path can shutdown() a reused fd number.
    private func endConnection(_ fd: Int32) {
        lock.lock()
        clientFDs.remove(fd)
        streamFDs.remove(fd)
        for id in sessions.keys where sessions[id]?.streamFD == fd {
            sessions[id]?.streamFD = nil
        }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        lock.unlock()
    }

    /// Unregister a stream fd. The GET connection thread notices on its next
    /// keepalive tick and closes the fd itself — callers never close it here,
    /// otherwise a recycled fd could be closed twice.
    private func dropStream(_ fd: Int32) {
        lock.lock()
        streamFDs.remove(fd)
        for id in sessions.keys where sessions[id]?.streamFD == fd {
            sessions[id]?.streamFD = nil
        }
        shutdownIfLive(fd)
        lock.unlock()
    }

    private func writeAll(_ fd: Int32, _ s: String) -> Bool {
        let bytes = Array(s.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    // MARK: - Request parsing

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]   // lowercased names
        var body: Data
    }

    /// Read one request. Returns nil on EOF/timeout/malformed.
    private func readRequest(_ fd: Int32) -> Request? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var headerEnd: Data.Index?
        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))?.lowerBound
            if buf.count > config.maxHeaderBytes, headerEnd == nil {
                return Request(method: "__too_large_headers__", path: "",
                               headers: [:], body: Data())
            }
        }
        guard let end = headerEnd else { return nil }
        let headerData = buf[buf.startIndex..<end]
        var rest = buf[(end + 4)...]
        guard let headerText = String(data: Data(headerData), encoding: .utf8) else {
            return nil
        }
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return Request(method: "__chunked__", path: "", headers: headers,
                           body: Data())
        }
        var length = 0
        if let cl = headers["content-length"], let n = Int(cl), n >= 0 {
            length = n
        } else if headers["content-length"] != nil {
            return nil
        }
        if length > config.maxBodyBytes {
            // Drain the declared body (bounded) so the client finishes its
            // upload and reliably sees the 413 instead of a mid-write RST.
            var remaining = min(length, config.maxBodyBytes * 2)
                - min(length, rest.count)
            while remaining > 0 {
                let n = read(fd, &chunk, min(chunk.count, remaining))
                guard n > 0 else { break }
                remaining -= n
            }
            return Request(method: "__too_large_body__", path: "", headers: headers,
                           body: Data())
        }
        while rest.count < length {
            let n = read(fd, &chunk, min(chunk.count, length - rest.count))
            guard n > 0 else { return nil }
            rest.append(contentsOf: chunk[0..<n])
        }
        let body = Data(rest[rest.startIndex..<rest.startIndex + length])
        return Request(method: String(parts[0]).uppercased(),
                       path: String(parts[1]), headers: headers, body: body)
    }

    // MARK: - Response helpers

    private func respond(_ fd: Int32, status: Int, text: String,
                         contentType: String = "application/json",
                         body: String = "", extra: [(String, String)] = []) {
        var out = "HTTP/1.1 \(status) \(text)\r\n"
        out += "Content-Type: \(contentType)\r\n"
        out += "Content-Length: \(body.utf8.count)\r\n"
        out += "Connection: close\r\n"
        for (k, v) in extra { out += "\(k): \(v)\r\n" }
        out += "\r\n" + body
        _ = writeAll(fd, out)
    }

    private func unauthorized(_ fd: Int32) {
        respond(fd, status: 401, text: "Unauthorized",
                body: "{\"error\":\"unauthorized\"}",
                extra: [("WWW-Authenticate", "Bearer realm=\"workshop\"")])
    }

    private func originAllowed(_ headers: [String: String]) -> Bool {
        guard let origin = headers["origin"] else { return true }
        var host = origin
        if let schemeEnd = host.range(of: "://") { host = String(host[schemeEnd.upperBound...]) }
        host = host.split(separator: "/").first.map(String.init) ?? host
        if host.hasPrefix("[") {
            return host.hasPrefix("[::1]")
        }
        host = host.split(separator: ":").first.map(String.init) ?? host
        return host == "127.0.0.1" || host == "localhost"
    }

    private func bearerToken(_ headers: [String: String]) -> String? {
        guard let auth = headers["authorization"],
              auth.hasPrefix("Bearer ") else { return nil }
        let token = String(auth.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    private func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func newSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, 16, &bytes) != errSecSuccess,
           let urandom = FileHandle(forReadingAtPath: "/dev/urandom") {
            bytes = Array(urandom.readData(ofLength: 16))
            try? urandom.close()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Look up a live session, expiring idle ones lazily.
    private func lookupSession(_ id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard var s = sessions[id] else { return nil }
        if Date().timeIntervalSince(s.lastSeen) > config.sessionIdleSeconds {
            if let stream = s.streamFD {
                streamFDs.remove(stream)
                shutdownIfLive(stream)
            }
            sessions.removeValue(forKey: id)
            return nil
        }
        s.lastSeen = Date()
        sessions[id] = s
        return s
    }

    // MARK: - Connection handling

    private func serveConnection(_ fd: Int32) {
        defer { endConnection(fd) }
        guard let req = readRequest(fd) else { return }
        switch req.method {
        case "__too_large_headers__":
            return respond(fd, status: 431, text: "Request Header Fields Too Large",
                           body: "{\"error\":\"headers too large\"}")
        case "__chunked__":
            return respond(fd, status: 411, text: "Length Required",
                           body: "{\"error\":\"chunked bodies not supported\"}")
        case "__too_large_body__":
            return respond(fd, status: 413, text: "Payload Too Large",
                           body: "{\"error\":\"body too large\"}")
        default: break
        }
        guard originAllowed(req.headers) else {
            return respond(fd, status: 403, text: "Forbidden",
                           body: "{\"error\":\"origin not allowed\"}")
        }
        // Auth on every request. Token values are never logged.
        guard let token = bearerToken(req.headers) else {
            return unauthorized(fd)
        }
        let principal: Principal
        do {
            principal = try awaitAuthenticate(token)
        } catch {
            return unauthorized(fd)
        }
        guard req.path == "/mcp" else {
            return respond(fd, status: 404, text: "Not Found",
                           body: "{\"error\":\"not found\"}")
        }
        switch req.method {
        case "POST":
            handlePost(fd, req: req, token: token, principal: principal)
        case "GET":
            handleGet(fd, req: req, token: token)
        case "DELETE":
            handleDelete(fd, req: req, token: token)
        default:
            respond(fd, status: 405, text: "Method Not Allowed",
                    body: "{\"error\":\"method not allowed\"}")
        }
    }

    /// Run the injected async authenticate without making serveConnection
    /// async: the connection thread blocks on a semaphore.
    private func awaitAuthenticate(_ token: String) throws -> Principal {
        var result: Result<Principal, Error>!
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { result = .success(try await authenticate(token)) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    // MARK: - /mcp handlers

    private func handlePost(_ fd: Int32, req: Request, token: String,
                            principal: Principal) {
        // Optional negotiated-version header must be one we speak.
        if let pv = req.headers["mcp-protocol-version"],
           !MCPProtocol.supportedVersions.contains(pv) {
            return respond(fd, status: 400, text: "Bad Request",
                           body: "{\"error\":\"unsupported MCP-Protocol-Version\"}")
        }
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: req.body),
              case .object = msg else {
            if case .array = (try? JSONDecoder().decode(JSONValue.self, from: req.body)) {
                return respond(fd, status: 400, text: "Bad Request",
                               body: "{\"error\":\"batch not supported\"}")
            }
            return respond(fd, status: 400, text: "Bad Request",
                           body: "{\"error\":\"invalid json-rpc\"}")
        }
        let method = msg["method"]?.stringValue ?? ""
        if method == "initialize" {
            let requested = msg["params"]?["protocolVersion"]?.stringValue ?? ""
            let version = MCPProtocol.supportedVersions.contains(requested)
                ? requested : MCPProtocol.defaultVersion
            lock.lock()
            if sessions.count >= config.maxSessions,
               let lru = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                if let old = sessions[lru]?.streamFD {
                    streamFDs.remove(old)
                    shutdownIfLive(old)
                }
                sessions.removeValue(forKey: lru)
            }
            let sid = newSessionID()
            sessions[sid] = Session(id: sid, tokenHash: tokenHash(token),
                                    protocolVersion: version, lastSeen: Date(),
                                    streamFD: nil)
            lock.unlock()
            let clientName = msg["params"]?["clientInfo"]?["name"]?.stringValue ?? "unknown"
            let clientVersion = msg["params"]?["clientInfo"]?["version"]?.stringValue ?? "unknown"
            logger?("mcp client session \(sid.prefix(8)) "
                + "principal=\(principal.displayName) "
                + "client=\(clientName)/\(clientVersion) protocol=\(version)")
            respondWithMessage(fd, msg: msg, sessionID: sid, token: token,
                               principal: principal)
            return
        }
        guard let sid = req.headers["mcp-session-id"], !sid.isEmpty else {
            return respond(fd, status: 400, text: "Bad Request",
                           body: "{\"error\":\"missing Mcp-Session-Id\"}")
        }
        guard let session = lookupSession(sid),
              session.tokenHash == tokenHash(token) else {
            return respond(fd, status: 404, text: "Not Found",
                           body: "{\"error\":\"session not found\"}")
        }
        respondWithMessage(fd, msg: msg, sessionID: sid, token: token,
                           principal: principal)
    }

    private func respondWithMessage(_ fd: Int32, msg: JSONValue, sessionID: String,
                                    token: String, principal: Principal) {
        guard let response = syncRespond(msg: msg, token: token,
                                         principal: principal) else {
            // Notification: accepted, no body.
            return respond(fd, status: 202, text: "Accepted",
                           contentType: "text/plain", body: "")
        }
        // A-5: per-call audit — method + tool name + outcome only, never
        // arguments or content.
        let id8 = sessionID.prefix(8)
        switch msg["method"]?.stringValue {
        case "tools/call":
            let name = msg["params"]?["name"]?.stringValue ?? "unknown"
            var isError = false
            if case .bool(let b) = response["result"]?["isError"] { isError = b }
            logger?("mcp call \(id8) principal=\(principal.displayName) "
                + "tool=\(name) \(isError ? "error" : "ok")")
        case "tools/list":
            let count = response["result"]?["tools"]?.arrayValue?.count ?? 0
            logger?("mcp list \(id8) principal=\(principal.displayName) "
                + "tools=\(count)")
        default:
            break
        }
        let body = String(decoding: (try? JSONEncoder().encode(response)) ?? Data(),
                          as: UTF8.self)
        var extra: [(String, String)] = []
        if msg["method"]?.stringValue == "initialize" {
            extra.append(("Mcp-Session-Id", sessionID))
        }
        respond(fd, status: 200, text: "OK", body: body, extra: extra)
    }

    /// Synchronous façade over MCPProtocol.respond + per-request
    /// authorize/callTool so the connection thread can stay blocking.
    private func syncRespond(msg: JSONValue, token: String,
                             principal: Principal) -> JSONValue? {
        var response: JSONValue?
        let sem = DispatchSemaphore(value: 0)
        Task {
            response = await MCPProtocol.respond(
                to: msg, serverVersion: serverVersion) { method, args in
                try await self.authorize(token, method, args)
                return try await self.callTool(method, args, principal)
            }
            sem.signal()
        }
        sem.wait()
        return response
    }

    private func handleGet(_ fd: Int32, req: Request, token: String) {
        guard let sid = req.headers["mcp-session-id"], !sid.isEmpty,
              let session = lookupSession(sid),
              session.tokenHash == tokenHash(token) else {
            return respond(fd, status: 404, text: "Not Found",
                           body: "{\"error\":\"session not found\"}")
        }
        guard (req.headers["accept"] ?? "").contains("text/event-stream") else {
            return respond(fd, status: 405, text: "Method Not Allowed",
                           body: "{\"error\":\"Accept must include text/event-stream\"}")
        }
        lock.lock()
        if streamFDs.count >= config.maxStreams {
            lock.unlock()
            return respond(fd, status: 409, text: "Conflict",
                           body: "{\"error\":\"too many open streams\"}")
        }
        if let old = sessions[sid]?.streamFD {
            // Replaced: unregister + shutdown; its connection thread closes it.
            streamFDs.remove(old)
            shutdownIfLive(old)
        }
        sessions[sid]?.streamFD = fd
        streamFDs.insert(fd)
        lock.unlock()
        var out = "HTTP/1.1 200 OK\r\n"
        out += "Content-Type: text/event-stream\r\n"
        out += "Cache-Control: no-cache\r\n"
        out += "Connection: close\r\n\r\n"
        _ = writeAll(fd, out)
        // Keep the stream open with periodic keepalives until the peer goes
        // away, the session is deleted, or the server stops. Sleep in 1 s
        // slices so a DELETEd session or stop() is noticed within ~1 s even
        // when keepaliveSeconds is long.
        var elapsed: TimeInterval = 0
        while running {
            Thread.sleep(forTimeInterval: min(1, max(0.05, config.keepaliveSeconds)))
            elapsed += min(1, config.keepaliveSeconds)
            lock.lock()
            let stillRegistered = streamFDs.contains(fd)
            lock.unlock()
            guard stillRegistered else { return }
            guard elapsed >= config.keepaliveSeconds else { continue }
            elapsed = 0
            if !writeAll(fd, ": keepalive\n\n") {
                dropStream(fd)
                return
            }
        }
    }

    private func handleDelete(_ fd: Int32, req: Request, token: String) {
        guard let sid = req.headers["mcp-session-id"], !sid.isEmpty else {
            return respond(fd, status: 400, text: "Bad Request",
                           body: "{\"error\":\"missing Mcp-Session-Id\"}")
        }
        lock.lock()
        guard let session = sessions[sid],
              session.tokenHash == tokenHash(token) else {
            lock.unlock()
            return respond(fd, status: 404, text: "Not Found",
                           body: "{\"error\":\"session not found\"}")
        }
        let streamFD = session.streamFD
        sessions.removeValue(forKey: sid)
        if let s = streamFD {
            streamFDs.remove(s)
            shutdownIfLive(s)
        }
        lock.unlock()
        logger?("mcp client session \(sid.prefix(8)) deleted")
        respond(fd, status: 200, text: "OK", body: "{}")
    }
}
