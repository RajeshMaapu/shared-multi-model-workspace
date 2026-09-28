import Foundation
import os
import WorkshopCore
import WorkshopService

/// Line-oriented transport for an ACP agent process.
public protocol ACPTransport: Sendable {
    /// Send one JSON-RPC line.
    func send(_ line: String) throws
    /// Receive lines until closed; nil element ends the stream.
    var lines: AsyncStream<String> { get }
    /// Terminate the underlying process (and its group) if running.
    func terminate()
    /// Captured child stderr (bounded, redacted) for diagnostics; empty for
    /// transports that are not child processes.
    var stderrText: String { get }
}

public extension ACPTransport {
    var stderrText: String { "" }
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
        let errPipe = Pipe()
        process.standardError = errPipe
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

        // Bounded stderr capture: 256 KiB ring per process (§14.5).
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        Thread {
            var tail = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(errFD, &chunk, chunk.count)
                if n <= 0 { break }
                tail.append(contentsOf: chunk[0..<n])
                if tail.count > 256 * 1024 {
                    tail = tail.suffix(256 * 1024)
                }
            }
            self.stderrTail = tail
        }.start()
    }

    /// Last ≤256 KiB of the child's stderr, redacted — for diagnostics.
    public private(set) var stderrTail = Data()
    public var stderrText: String {
        Redactor.shared.redact(String(decoding: stderrTail, as: UTF8.self))
    }

    public func send(_ line: String) throws {
        var data = Data(line.utf8)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    public func terminate() {
        let pid = process.processIdentifier
        if pid > 0, process.isRunning {
            // Foundation's post-spawn setpgid can fail. Never signal a group
            // we have not verified, and never reuse an exited child's PID.
            if getpgid(pid) == pid { kill(-pid, SIGKILL) }
            if process.isRunning { process.terminate() }
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
    private var capabilities: TurnCapabilityManifest = .writer
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var toolCalls: [String: JSONValue] = [:]
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

    /// Residual permission policy for the current turn; the per-generation
    /// sandbox is the enforcement boundary.
    public func setCapabilities(_ manifest: TurnCapabilityManifest) {
        capabilities = manifest
    }

    /// Current manifest — exposed for adapter tests.
    public var currentCapabilities: TurnCapabilityManifest { capabilities }

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
    public func call(_ method: String, params: JSONValue? = nil,
                     timeout: Duration? = nil) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        if let timeout {
            Task {
                try? await Task.sleep(for: timeout)
                self.expireRequest(id, method: method)
            }
        }
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

    private func expireRequest(_ id: Int64, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: ACPError.timeout(method))
        close()
    }

    /// JSON-RPC notification: intentionally no id and no response waiter.
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        let data = try JSONEncoder().encode(JSONValue.object(message))
        try transport.send(String(decoding: data, as: UTF8.self))
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
            if update["sessionUpdate"]?.stringValue == "tool_call",
               let callID = update["toolCallId"]?.stringValue {
                toolCalls[callID] = update
            }
            emit(.sessionUpdate(update))
        }
    }

    /// Permission policy: decided by the ACP tool `kind` against the turn's
    /// capability manifest — never by title/label string matching. The
    /// per-generation sandbox is the enforcement boundary; this only shapes
    /// the residual prompts.
    private func respondToPermission(id: JSONValue, params: JSONValue?) {
        // Diagnostic: append the raw request to <WORKSHOP_DIAG_DIR>/
        // permission-requests.log when the env var is set (never secrets —
        // tool titles and option kinds only).
        if let dir = ProcessInfo.processInfo.environment["WORKSHOP_DIAG_DIR"],
           let data = try? JSONEncoder().encode(params ?? .null) {
            let path = dir + "/permission-requests.log"
            let line = String(decoding: data, as: UTF8.self) + "\n"
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(Data(line.utf8)); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: path,
                                               contents: Data(line.utf8))
            }
        }
        let options = params?["options"]?.arrayValue ?? []
        let call = params?["toolCall"]
        let prior = call?["toolCallId"]?.stringValue.flatMap { toolCalls[$0] }
        let title = call?["title"]?.stringValue ?? prior?["title"]?.stringValue ?? ""
        switch ACPPermissionPolicy.decide(request: params ?? .null,
                                          priorToolCall: prior,
                                          capabilities: capabilities) {
        case .allow(let optionID):
            let chosen = options.first { $0["optionId"] == optionID }
            sendRaw(["jsonrpc": .string("2.0"), "id": id,
                     "result": .object(["outcome": .object([
                        "outcome": .string("selected"),
                        "optionId": optionID])])])
            emit(.permissionRequested(title: title,
                                      chosen: chosen?["name"]?.stringValue ?? "allow"))
        case .reject(let optionID):
            // Redacted denial shape for post-mortem diagnosis (field names
            // and lengths only — no titles, commands, or arguments).
            if let dir = ProcessInfo.processInfo.environment["WORKSHOP_DIAG_DIR"] {
                func fieldNames(_ value: JSONValue?) -> String {
                    if case .object(let fields) = value {
                        return fields.keys.sorted().joined(separator: ",")
                    }
                    return "none"
                }
                let line = "permission declined shape: call=\(fieldNames(call))"
                    + " prior=\(fieldNames(prior)) options=\(options.count)"
                    + " titleLength=\(title.count)\n"
                let path = dir + "/permission-requests.log"
                if let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile(); fh.write(Data(line.utf8)); fh.closeFile()
                } else {
                    FileManager.default.createFile(atPath: path,
                                                   contents: Data(line.utf8))
                }
            }
            if let optionID {
                sendRaw(["jsonrpc": .string("2.0"), "id": id,
                         "result": .object(["outcome": .object([
                            "outcome": .string("selected"),
                            "optionId": optionID])])])
            } else {
                sendRaw(["jsonrpc": .string("2.0"), "id": id,
                         "error": .object(["code": .number(-32601),
                                           "message": .string("no option")])])
            }
            emit(.permissionDenied(title))
        case .noOption:
            sendRaw(["jsonrpc": .string("2.0"), "id": id,
                     "error": .object(["code": .number(-32601),
                                       "message": .string("no option")])])
            emit(.permissionDenied(title))
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
        case timeout(String)
    }

    /// Redacted tail of the child's stderr, when the transport captures it —
    /// the harness's own diagnostics (e.g. a team-settings timeout) live here.
    public nonisolated var transportStderrText: String { transport.stderrText }
}

/// Residual ACP permission policy: decided by the structured tool `kind`
/// against the turn's capability manifest. No title/label string matching —
/// the sandbox is the enforcement boundary.
public enum ACPPermissionPolicy {
    public enum Decision: Sendable, Equatable {
        case allow(optionID: JSONValue)
        case reject(optionID: JSONValue?)
        case noOption
    }

    /// Decide one `session/request_permission` request.
    /// - `request`: the request's `params` object.
    /// - `priorToolCall`: the correlated `session/update` tool_call, when the
    ///   request carried only a `toolCallId`.
    public static func decide(request: JSONValue, priorToolCall: JSONValue?,
                              capabilities: TurnCapabilityManifest) -> Decision {
        let call = request["toolCall"]
        let options = request["options"]?.arrayValue ?? []
        let kind = call?["kind"]?.stringValue ?? priorToolCall?["kind"]?.stringValue
        let toolName = call?["_meta"]?["cognition.ai/inferenceToolName"]?.stringValue
            ?? call?["_meta"]?["cognition.ai/toolName"]?.stringValue
            ?? priorToolCall?["_meta"]?["cognition.ai/inferenceToolName"]?.stringValue
            ?? priorToolCall?["_meta"]?["cognition.ai/toolName"]?.stringValue
            ?? priorToolCall?["title"]?.stringValue ?? ""
        func option(matching prefix: String) -> JSONValue? {
            options.first { $0["kind"]?.stringValue?.hasPrefix(prefix) == true }
        }
        // Workshop never expands the sandbox scope from a prompt.
        let denied = toolName == "request_scope"
            || (["edit", "delete", "move"].contains(kind) && !capabilities.edit)
            || (kind == "execute" && !capabilities.execute)
            || (kind == "fetch" && !capabilities.fetch)
        if denied {
            let reject = option(matching: "reject") ?? options.first
            guard let reject else { return .noOption }
            return .reject(optionID: reject["optionId"])
        }
        if let allow = options.first(where: {
            $0["kind"]?.stringValue == "allow_once"
        }) ?? option(matching: "allow") {
            return .allow(optionID: allow["optionId"] ?? .null)
        }
        return .noOption
    }
}

extension ACPClient.ACPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .remote(let code, let message):
            return "ACP remote error \(code): \(message)"
        case .timeout(let method):
            return "ACP \(method) timed out"
        }
    }
}
