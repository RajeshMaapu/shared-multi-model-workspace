import Foundation
import WorkshopCore

/// Line-delimited JSON-RPC client for the Workshop Unix socket.
public actor WorkshopClient {
    public struct RemoteError: WorkshopRPCError, Equatable {
        public let code: Int
        public let message: String
        public var rpcCode: Int { code }
    }

    private var fd: Int32 = -1
    private var nextID: Int64 = 1
    private var authenticated = false
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var notificationContinuations: [UUID: AsyncStream<JSONRPCNotification>.Continuation] = [:]
    private let socketPath: String

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath
            ?? IPCServer.defaultRuntimeDir() + "/service.sock"
    }

    /// Open the connection. Throws if the daemon is not listening.
    public func connect() throws {
        guard fd < 0 else { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw IPCError.socketFailed("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < 104 else {
            Darwin.close(s)
            throw IPCError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[pathBytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(s)
            throw IPCError.notConnected
        }
        authenticated = false
        fd = s
        let capturedFD = s
        Thread { [weak self] in self?.readLoop(fd: capturedFD) }.start()
    }

    public func disconnect() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        for (_, continuation) in pending {
            continuation.resume(throwing: IPCError.notConnected)
        }
        pending.removeAll()
        for continuation in notificationContinuations.values { continuation.finish() }
        notificationContinuations.removeAll()
    }

    /// Stream of server notifications (`workshop.event`).
    public func makeNotificationStream() -> AsyncStream<JSONRPCNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { _ in
                // continuations dropped on disconnect
            }
        }
    }

    /// One JSON-RPC call.
    public func call(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        if method != WorkshopProtocol.authenticate, !authenticated {
            let path = (socketPath as NSString).deletingLastPathComponent + "/user.token"
            if let token = try? String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                _ = try await rawCall(WorkshopProtocol.authenticate, params: .object(["token": .string(token)]))
                authenticated = true
            }
        }
        let result = try await rawCall(method, params: params)
        if method == WorkshopProtocol.authenticate { authenticated = true }
        return result
    }

    private func rawCall(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let request = JSONRPCRequest(id: .number(Double(id)), method: method, params: params)
            do {
                let data = try JSONEncoder().encode(request)
                var line = data
                line.append(0x0A)
                try line.withUnsafeBytes { ptr in
                    var sent = 0
                    while sent < line.count {
                        let n = write(fd, ptr.baseAddress!.advanced(by: sent), line.count - sent)
                        if n <= 0 { throw IPCError.notConnected }
                        sent += n
                    }
                }
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Typed convenience: decode the result.
    public func call<T: Decodable>(_ method: String, params: JSONValue? = nil,
                                   as type: T.Type) async throws -> T {
        try await call(method, params: params).decode(as: T.self)
    }

    private nonisolated func readLoop(fd readFD: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(readFD, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                Task { await self.handle(line: line) }
            }
        }
        Task { await self.connectionClosed() }
    }

    private func handle(line: Data) {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: line),
              case .object = object else { return }
        if object["method"]?.stringValue != nil {
            if let notification = try? JSONDecoder().decode(JSONRPCNotification.self, from: line) {
                for continuation in notificationContinuations.values {
                    continuation.yield(notification)
                }
            }
            return
        }
        guard let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: line),
              let id = response.id?.intValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = response.error {
            continuation.resume(throwing: RemoteError(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: response.result ?? .null)
        }
    }

    private func connectionClosed() {
        disconnect()
    }
}
