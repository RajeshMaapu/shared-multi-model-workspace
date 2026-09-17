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
        case permissionDecision(ACPPermissionDecision)
    }

    private let transport: ACPTransport
    private let permissionPolicy: ACPPermissionPolicy
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
    /// Synchronous sink invoked inside the read loop — events emitted while a
    /// `call` is in flight are guaranteed delivered before that call resumes.
    private var eventSink: (@Sendable (ServerEvent) -> Void)?
    private var readerTask: Task<Void, Never>?
    private var toolCalls: [String: JSONValue] = [:]
    private var toolCallOrder: [String] = []
    private let log = Logger(subsystem: "ai.maapu.workshop", category: "acp")

    public init(transport: ACPTransport,
                permissionPolicy: ACPPermissionPolicy = ACPPermissionPolicy()) {
        self.transport = transport
        self.permissionPolicy = permissionPolicy
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
            if update["sessionUpdate"]?.stringValue == "tool_call"
                || update["sessionUpdate"]?.stringValue == "tool_call_update" {
                rememberToolCall(sessionID: msg["params"]?["sessionId"]?.stringValue,
                                 update: update)
            }
            emit(.sessionUpdate(update))
        }
    }

    // Some ACP servers (Devin) send only toolCallId in `toolCall`; the
    // permission request may carry no typed fields at all.
    // Structured identity must come from the matching session/update.
    private func rememberToolCall(sessionID: String?, update: JSONValue) {
        guard let sessionID, let callID = update["toolCallId"]?.stringValue,
              !sessionID.isEmpty, !callID.isEmpty,
              sessionID.count <= 256, callID.count <= 256,
              !sessionID.contains("\0"), !callID.contains("\0") else { return }
        let key = sessionID + "\0" + callID
        var stored = toolCalls[key]?.objectValue ?? [:]
        let identity = ACPPermissionPolicy.identity(update)
        if identity.conflict { stored["_workshopIdentityConflict"] = .bool(true) }
        if !identity.name.isEmpty {
            if let old = stored["_meta"]?["cognition.ai/toolName"]?.stringValue, old != identity.name {
                stored["_workshopIdentityConflict"] = .bool(true)
            }
            stored["_meta"] = .object(["cognition.ai/toolName": .string(identity.name)])
        }
        if let kind = update["kind"]?.stringValue {
            if let old = stored["kind"]?.stringValue, old != kind {
                stored["_workshopIdentityConflict"] = .bool(true)
            }
            stored["kind"] = .string(kind)
        }
        if let raw = update["rawInput"] {
            if let data = try? JSONEncoder().encode(raw), data.count <= 64 * 1024 {
                stored["rawInput"] = raw
            } else {
                stored["_workshopIdentityConflict"] = .bool(true)
                stored.removeValue(forKey: "rawInput")
            }
        }
        stored["toolCallId"] = .string(callID)
        if toolCalls[key] == nil {
            toolCallOrder.append(key)
            while toolCallOrder.count > 256 {
                let oldest = toolCallOrder.removeFirst()
                toolCalls.removeValue(forKey: oldest)
            }
        }
        toolCalls[key] = .object(stored)
    }

    private func resolvedToolCall(_ params: JSONValue?) -> (JSONValue, Bool) {
        let request = params?["toolCall"] ?? .object([:])
        var requestFields = request.objectValue ?? [:]
        let identity = ACPPermissionPolicy.identity(request)
        if identity.name.isEmpty { requestFields.removeValue(forKey: "_meta") }
        else { requestFields["_meta"] = .object(["cognition.ai/toolName": .string(identity.name)]) }
        guard let sessionID = params?["sessionId"]?.stringValue,
              let callID = requestFields["toolCallId"]?.stringValue,
              !sessionID.isEmpty, !callID.isEmpty,
              sessionID.count <= 256, callID.count <= 256,
              !sessionID.contains("\0"), !callID.contains("\0"),
              var remembered = toolCalls[sessionID + "\0" + callID]?.objectValue else {
            return (request, false)
        }
        var conflicting = identity.conflict || remembered["_workshopIdentityConflict"] != nil
        remembered.removeValue(forKey: "_workshopIdentityConflict")
        for field in ["_meta", "kind"] {
            guard let old = remembered[field], let new = requestFields[field] else { continue }
            if field == "_meta" {
                let oldName = old["cognition.ai/toolName"]?.stringValue
                let newName = new["cognition.ai/toolName"]?.stringValue
                if let oldName, let newName, oldName != newName { conflicting = true }
            } else if let oldKind = old.stringValue, let newKind = new.stringValue,
                      oldKind != newKind {
                conflicting = true
            }
        }
        var merged = remembered
        for field in ["_meta", "kind", "rawInput", "toolCallId"] where requestFields[field] != nil {
            merged[field] = requestFields[field]
        }
        return (.object(merged), conflicting)
    }

    /// Permission policy: allow_once for typed tools and explicit scoped
    /// commands; everything else selects a reject option or cancels.
    private func respondToPermission(id: JSONValue, params: JSONValue?) {
        let (toolCall, conflicting) = resolvedToolCall(params)
        var decision = permissionPolicy.decide(toolCall: toolCall)
        if conflicting { decision.allowed = false; decision.reason = "conflicting_tool_update" }
        let options = params?["options"]?.arrayValue ?? []
        let valid = options.filter { !($0["optionId"]?.stringValue ?? "").isEmpty }
        let allow = valid.first { $0["kind"]?.stringValue == "allow_once" }
        if decision.allowed && allow == nil { decision.allowed = false; decision.reason = "allow_once_unavailable" }
        let chosen = decision.allowed ? allow : valid.first { $0["kind"]?.stringValue == "reject_once" }
            ?? valid.first { $0["kind"]?.stringValue == "reject_always" }
        let outcome: JSONValue = chosen.map {
            .object(["outcome": .string("selected"), "optionId": $0["optionId"]!])
        } ?? .object(["outcome": .string("cancelled")])
        sendRaw(["jsonrpc": .string("2.0"), "id": id, "result": .object(["outcome": outcome])])
        emit(.permissionDecision(decision))
        if decision.allowed { emit(.permissionRequested(title: decision.title, chosen: "allow_once")) }
        else { emit(.permissionDenied(decision.title)) }
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
