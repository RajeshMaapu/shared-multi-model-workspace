import Foundation
import WorkshopCore

public enum IPCError: Error, Equatable {
    case socketFailed(String)
    case pathTooLong
    case peerRejected
    case notConnected
    case remoteError(Int, String)
}

/// One accepted connection.
public final class Connection: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()
    private var closed = false
    /// Principal bound to this connection by workshop.authenticate; .user default.
    var principal: Principal = .user
    var token: String?

    init(fd: Int32) { self.fd = fd }

    func send(line: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        var data = Data(line.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
                if n <= 0 { closed = true; break }
                sent += n
            }
        }
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !closed {
            closed = true
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// Newline-delimited JSON-RPC 2.0 server over a private Unix-domain socket.
public final class IPCServer: @unchecked Sendable {
    public static let maxLineBytes = 4 * 1024 * 1024

    public let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false
    private var connections: [Int32: Connection] = [:]
    private var subscribers: Set<Int32> = []
    private let lock = NSLock()

    /// Async method handler; the third arg is the connection's authenticated
    /// principal (.user when unauthenticated). Throws WorkshopError.
    public var handler: ((String, JSONValue?, Principal) async throws -> JSONValue)?
    /// Resolve a capability token to a principal (workshop.authenticate).
    public var requestAuthorizer: ((String?, String, JSONValue?) async throws -> Void)?
    public var requiresAuthentication = false
    public var authenticator: ((String) async throws -> Principal)?
    /// Replay events after a seq for a new subscriber.
    public var replayEvents: ((Int64) -> [OutboxEvent])?

    public init(socketPath: String) throws {
        guard socketPath.utf8.count < 100 else { throw IPCError.pathTooLong }
        self.socketPath = socketPath
    }

    /// Default runtime directory `${DARWIN_USER_TEMP_DIR}/workshop` (mode 0700).
    public static func defaultRuntimeDir() -> String {
        if let override = ProcessInfo.processInfo.environment["WORKSHOP_RUNTIME_DIR"],
           !override.isEmpty {
            return override
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let tmp = len > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return tmp + "workshop"
    }

    public func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw IPCError.socketFailed("socket: \(errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw IPCError.socketFailed("bind: \(errnoString())")
        }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 16) == 0 else {
            throw IPCError.socketFailed("listen: \(errnoString())")
        }
        running = true
        acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread?.start()
    }

    public func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.close() }
        unlink(socketPath)
    }

    /// Push a notification to every subscribed connection.
    public func broadcast(_ notification: JSONRPCNotification) {
        guard let data = try? JSONEncoder().encode(notification),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let targets = subscribers.compactMap { connections[$0] }
        lock.unlock()
        for conn in targets { conn.send(line: line) }
    }

    private func acceptLoop() {
        while running {
            var peer = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(listenFD, &peer, &len)
            if fd < 0 { if running { continue } else { break } }

            // Same-uid peer check (macOS getpeereid is the LOCAL_PEERCRED equivalent).
            var uid = uid_t(0), gid = gid_t(0)
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(fd)
                continue
            }
            let conn = Connection(fd: fd)
            lock.lock()
            connections[fd] = conn
            lock.unlock()
            Thread { [weak self] in self?.readLoop(conn) }.start()
        }
    }

    private func removeConnection(_ conn: Connection) {
        lock.lock()
        connections.removeValue(forKey: conn.fd)
        subscribers.remove(conn.fd)
        lock.unlock()
        conn.close()
    }

    private func readLoop(_ conn: Connection) {
        var buffer = Data()
        var discarding = false
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = read(conn.fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if discarding {
                    discarding = false
                    continue
                }
                handle(line: Data(line), conn: conn)
            }
            if buffer.count > Self.maxLineBytes, !discarding {
                sendError(id: nil, code: WorkshopProtocol.ErrorCode.parseError,
                          message: "Line exceeds 4 MiB limit", to: conn)
                discarding = true
                buffer.removeAll(keepingCapacity: true)
            }
        }
        removeConnection(conn)
    }

    private func handle(line: Data, conn: Connection) {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line),
              request.jsonrpc == "2.0", !request.method.isEmpty else {
            sendError(id: nil, code: WorkshopProtocol.ErrorCode.parseError,
                      message: "Parse error", to: conn)
            return
        }
        Task {
            if request.method == WorkshopProtocol.authenticate {
                handleAuthenticate(request: request, conn: conn)
                return
            }
            if requiresAuthentication {
                guard let token = conn.token, let authenticator else {
                    sendError(id: request.id, code: -32001, message: "Authentication required", to: conn)
                    return
                }
                do { conn.principal = try await authenticator(token) }
                catch {
                    sendError(id: request.id, code: -32001, message: "Authentication expired", to: conn)
                    return
                }
            }
            if let requestAuthorizer {
                do { try await requestAuthorizer(conn.token, request.method, request.params) }
                catch {
                    sendError(id: request.id, code: -32001, message: "Request outside capability scope", to: conn)
                    return
                }
            }
            if request.method == WorkshopProtocol.subscribe {
                handleSubscribe(request: request, conn: conn)
                return
            }
            guard let handler else {
                sendError(id: request.id, code: WorkshopProtocol.ErrorCode.methodNotFound,
                          message: "Method not found: \(request.method)", to: conn)
                return
            }
            do {
                let result = try await handler(request.method, request.params, conn.principal)
                respond(id: request.id, result: result, to: conn)
            } catch let error as WorkshopRPCError {
                sendError(id: request.id, code: error.rpcCode, message: error.message, to: conn)
            } catch {
                sendError(id: request.id, code: WorkshopProtocol.ErrorCode.internalError,
                          message: String(describing: error), to: conn)
            }
        }
    }

    private func handleAuthenticate(request: JSONRPCRequest, conn: Connection) {
        Task {
            guard let token = request.params?["token"]?.stringValue,
                  let authenticator else {
                sendError(id: request.id, code: WorkshopProtocol.ErrorCode.invalidParams,
                          message: "Authentication not supported", to: conn)
                return
            }
            do {
                conn.principal = try await authenticator(token)
                conn.token = token
                respond(id: request.id,
                        result: .object(["principal": .string(conn.principal.displayName)]),
                        to: conn)
            } catch let error as WorkshopRPCError {
                sendError(id: request.id, code: error.rpcCode, message: error.message, to: conn)
            } catch {
                sendError(id: request.id, code: WorkshopProtocol.ErrorCode.internalError,
                          message: String(describing: error), to: conn)
            }
        }
    }

    private func handleSubscribe(request: JSONRPCRequest, conn: Connection) {
        let afterSeq = request.params?["after_seq"]?.intValue ?? 0
        lock.lock()
        subscribers.insert(conn.fd)
        lock.unlock()
        for event in replayEvents?(afterSeq) ?? [] {
            notify(event: event, to: conn)
        }
        respond(id: request.id, result: .object(["subscribed": .bool(true)]), to: conn)
    }

    private func notify(event: OutboxEvent, to conn: Connection) {
        let params: JSONValue = .object([
            "seq": .number(Double(event.seq)),
            "task_id": event.taskID.map { .string($0.rawValue) } ?? .null,
            "type": .string(event.eventType),
            "payload": .string(event.payload),
        ])
        broadcastOrSend(JSONRPCNotification(method: WorkshopProtocol.eventNotification,
                                            params: params), to: conn)
    }

    /// Send an outbox event to all subscribers.
    public func broadcastEvent(_ event: OutboxEvent) {
        lock.lock()
        let targets = subscribers.compactMap { connections[$0] }
        lock.unlock()
        for conn in targets { notify(event: event, to: conn) }
    }

    private func broadcastOrSend(_ notification: JSONRPCNotification, to conn: Connection) {
        guard let data = try? JSONEncoder().encode(notification),
              let line = String(data: data, encoding: .utf8) else { return }
        conn.send(line: line)
    }

    private func respond(id: JSONValue?, result: JSONValue, to conn: Connection) {
        let response = JSONRPCResponse(id: id ?? .null, result: result)
        guard let data = try? JSONEncoder().encode(response),
              let line = String(data: data, encoding: .utf8) else { return }
        conn.send(line: line)
    }

    private func sendError(id: JSONValue?, code: Int, message: String, to conn: Connection) {
        let response = JSONRPCResponse(id: id ?? .null,
                                       error: JSONRPCErrorObject(code: code, message: message))
        guard let data = try? JSONEncoder().encode(response),
              let line = String(data: data, encoding: .utf8) else { return }
        conn.send(line: line)
    }

    private func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
