import Foundation
import os
import WorkshopCore

/// Line-oriented transport for an ACP agent process.
public protocol ACPTransport: Sendable {
    /// Send one JSON-RPC line.
    func send(_ line: String) throws
    /// Receive lines until closed; nil element ends the stream.
    var lines: AsyncStream<String> { get }
    /// Terminate the underlying process (and its group) if running.
    func terminate()
}

/// ACP transport over a spawned process's stdin/stdout. The child runs in its
/// own process group so cancel can kill the whole tree.
public final class ProcessACPTransport: ACPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let linesContinuation: AsyncStream<String>.Continuation
    public let lines: AsyncStream<String>

    /// `argv[0]` is the executable; `env` is the full environment; `cwd` the workdir.
    public init(argv: [String], env: [String: String], cwd: String) throws {
        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.stdinHandle = inPipe.fileHandleForWriting

        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        linesContinuation = continuation

        try process.run()
        // Child was spawned via posix_spawn by Foundation; give it its own group
        // so terminate() can signal the tree.
        setpgid(process.processIdentifier, 0)

        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let cont = linesContinuation
        Thread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(outFD, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if line.count > IPCFree.maxLineBytes { continue }
                    cont.yield(String(decoding: line, as: UTF8.self))
                }
            }
            cont.finish()
        }.start()
    }

    public func send(_ line: String) throws {
        var data = Data(line.utf8)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    public func terminate() {
        let pid = process.processIdentifier
        if pid > 0 {
            // Kill the process group (start_new_session semantics).
            kill(-pid, SIGKILL)
            process.terminate()
        }
        try? stdinHandle.close()
    }
}

/// Small shared bound constant (4 MiB) without depending on WorkshopIPC.
public enum IPCFree {
    public static let maxLineBytes = 4 * 1024 * 1024
}

/// Minimal JSON-RPC 2.0 client over an ACPTransport: correlation by id,
/// notifications and server→client requests (permission policy).
public actor ACPClient {
    /// One server→client request seen by the client (e.g. permission requests).
    public enum ServerEvent: Sendable, Equatable {
        case sessionUpdate(JSONValue)
        case permissionRequested(title: String, chosen: String)
        case permissionDenied(String)
    }

    private let transport: ACPTransport
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
    /// Synchronous sink invoked inside the read loop — events emitted while a
    /// `call` is in flight are guaranteed delivered before that call resumes.
    private var eventSink: (@Sendable (ServerEvent) -> Void)?
    private var readerTask: Task<Void, Never>?
    private let log = Logger(subsystem: "ai.maapu.workshop", category: "acp")

    public init(transport: ACPTransport) {
        self.transport = transport
        let t = transport
        readerTask = Task { await self.readLoop(t.lines) }
    }

    public func events() -> AsyncStream<ServerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
        }
    }

    /// Install (or clear) the synchronous event sink used during a turn.
    public func setEventSink(_ sink: (@Sendable (ServerEvent) -> Void)?) {
        eventSink = sink
    }

    /// Send a request and await its correlated response.
    @discardableResult
    public func call(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            var request: [String: JSONValue] = [
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "method": .string(method),
            ]
            if let params { request["params"] = params }
            do {
                let data = try JSONEncoder().encode(JSONValue.object(request))
                try transport.send(String(decoding: data, as: UTF8.self))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    public func close() {
        transport.terminate()
        readerTask?.cancel()
        for (_, c) in pending { c.resume(throwing: CancellationError()) }
        pending.removeAll()
        for c in eventContinuations.values { c.finish() }
    }

    private func readLoop(_ lines: AsyncStream<String>) async {
        for await line in lines {
            guard let msg = try? JSONDecoder().decode(JSONValue.self,
                                                      from: Data(line.utf8)) else {
                // Malformed line: log and continue (T21).
                log.error("ACP: dropped malformed line (\(line.count, privacy: .public) bytes)")
                continue
            }
            await handle(msg)
        }
        for (_, c) in pending { c.resume(throwing: CancellationError()) }
        pending.removeAll()
        for c in eventContinuations.values { c.finish() }
    }

    private func handle(_ msg: JSONValue) {
        guard case .object = msg else { return }
        // Response to one of our requests.
        if msg["method"] == nil, let id = msg["id"]?.intValue {
            if let continuation = pending.removeValue(forKey: id) {
                if let error = msg["error"] {
                    continuation.resume(throwing: ACPError.remote(
                        Int(error["code"]?.intValue ?? -32603),
                        error["message"]?.stringValue ?? "error"))
                } else {
                    continuation.resume(returning: msg["result"] ?? .null)
                }
            }
            return
        }
        // Server→client request (has method + id): permission policy.
        if let method = msg["method"]?.stringValue, let id = msg["id"] {
            if method == "session/request_permission" {
                respondToPermission(id: id, params: msg["params"])
            } else {
                sendRaw(["jsonrpc": .string("2.0"), "id": id,
                         "error": .object(["code": .number(-32601),
                                           "message": .string("Client capability not offered")])])
            }
            return
        }
        // Notification.
        if msg["method"]?.stringValue == "session/update",
           let update = msg["params"]?["update"] {
            emit(.sessionUpdate(update))
        }
    }

    /// Permission policy: allow_once for workshop tools and read-only titles;
    /// reject everything else and surface a permissionDenied event.
    private func respondToPermission(id: JSONValue, params: JSONValue?) {
        let options = params?["options"]?.arrayValue ?? []
        let title = params?["toolCall"]?["title"]?.stringValue ?? ""
        let rawName = params?["toolCall"]?["_meta"]?["cognition.ai/toolName"]?.stringValue ?? ""
        let isWorkshop = rawName.hasPrefix("mcp__workshop__") || title.contains("workshop")
        let isReadOnly = ["Read", "Grep", "List", "Glob"].contains { title.hasPrefix($0) }
        func option(matching prefix: String) -> JSONValue? {
            options.first { $0["kind"]?.stringValue?.hasPrefix(prefix) == true }
        }
        if isWorkshop || isReadOnly, let allow = option(matching: "allow") {
            sendRaw(["jsonrpc": .string("2.0"), "id": id,
                     "result": .object(["outcome": .object([
                        "outcome": .string("selected"),
                        "optionId": allow["optionId"] ?? .null])])])
            emit(.permissionRequested(title: title,
                                      chosen: allow["name"]?.stringValue ?? "allow"))
        } else {
            let reject = option(matching: "reject") ?? options.first
            if let reject {
                sendRaw(["jsonrpc": .string("2.0"), "id": id,
                         "result": .object(["outcome": .object([
                            "outcome": .string("selected"),
                            "optionId": reject["optionId"] ?? .null])])])
            } else {
                sendRaw(["jsonrpc": .string("2.0"), "id": id,
                         "error": .object(["code": .number(-32601),
                                           "message": .string("no option")])])
            }
            emit(.permissionDenied(title.isEmpty ? rawName : title))
        }
    }

    private func sendRaw(_ object: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return }
        try? transport.send(String(decoding: data, as: UTF8.self))
    }

    private func emit(_ event: ServerEvent) {
        eventSink?(event)
        for c in eventContinuations.values { c.yield(event) }
    }

    public enum ACPError: Error, Equatable {
        case remote(Int, String)
    }
}
