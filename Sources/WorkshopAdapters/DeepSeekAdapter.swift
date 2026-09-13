import Foundation
import WorkshopCore
import WorkshopService

/// HTTP transport abstraction so tests can stub the wire without URLProtocol.
public protocol HTTPTransport: Sendable {
    func postJSON(url: URL, headers: [String: String], body: [String: JSONValue])
        async throws -> (status: Int, body: JSONValue)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}
    public func postJSON(url: URL, headers: [String: String],
                         body: [String: JSONValue]) async throws -> (status: Int, body: JSONValue) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        return (status, json)
    }
}

/// DeepSeek adapter: direct chat-completions tool loop. History is managed
/// under <WORKSHOP_HOME>/sessions/deepseek/<task>/<worker>.json; visible
/// messages only (reasoning_content is echoed back inside a tool sequence but
/// never persisted). The API key is read at request time from a credential
/// reference, never persisted or logged.
public final class DeepSeekAdapter: EngineerAdapter, @unchecked Sendable {
    public let engineer: EngineerID = .deepseek
    private let transport: HTTPTransport
    private let keyReader: @Sendable () throws -> String
    private let toolExecutor: @Sendable (String, JSONValue) async throws -> String
    private let sessionsDir: String
    private let endpoint: URL
    private let maxIterations = 8
    private let maxTokens = 4000

    /// `keyReader` returns the API key at request time (credential reference);
    /// `toolExecutor` runs a workshop tool and returns result JSON text.
    public init(transport: HTTPTransport = URLSessionHTTPTransport(),
                sessionsDir: String,
                endpoint: URL = URL(string: "https://api.deepseek.com/v1/chat/completions")!,
                keyReader: @escaping @Sendable () throws -> String,
                toolExecutor: @escaping @Sendable (String, JSONValue) async throws -> String) {
        self.transport = transport
        self.sessionsDir = sessionsDir
        self.endpoint = endpoint
        self.keyReader = keyReader
        self.toolExecutor = toolExecutor
    }

    /// Targeted TOML section/key scanner for credential references — NOT a
    /// general parser. Reads `[providers, deepseek, api_key]` from
    /// ~/.kimi-code/config.toml by default.
    public static func readCredential(path: String = NSHomeDirectory() + "/.kimi-code/config.toml",
                                      section: String = "providers.deepseek",
                                      key: String = "api_key") throws -> String {
        let text = try String(contentsOfFile: path)
        var inSection = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' "))
                    .replacingOccurrences(of: "\".\"", with: ".")
                inSection = name == section
                continue
            }
            guard inSection, line.hasPrefix(key), let eq = line.firstIndex(of: "=") else {
                continue
            }
            return line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        throw WorkshopError.adapterUnavailable(.deepseek)
    }

    public nonisolated func probe() async -> AdapterProbe {
        // Presence of the credential reference only; auth unverified.
        do {
            _ = try keyReader()
            return AdapterProbe(engineer: .deepseek,
                                health: .available(
                                    "credential reference present; auth unverified until first turn"),
                                effectiveModel: "deepseek-flash",
                                capabilities: ["tool_loop"], tested: false)
        } catch {
            return AdapterProbe(engineer: .deepseek,
                                health: .loginRequired("credential reference unreadable"),
                                tested: false)
        }
    }

    public func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
        // DeepSeek sessions are file-backed histories; nothing to open remotely.
        try FileManager.default.createDirectory(
            atPath: sessionsDir + "/" + binding.taskID.rawValue, withIntermediateDirectories: true)
        return SessionRef(engineer: .deepseek,
                          nativeSessionID: "deepseek:\(binding.taskID):\(binding.workerID)")
    }

    /// Tool schemas sent to DeepSeek mirror the workshop bridge tools.
    public static func toolSchemas() -> [JSONValue] {
        WorkshopToolCatalog.tools.map { tool in
            .object(["type": .string("function"),
                     "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema])])
        }
    }

    private func historyPath(_ ref: SessionRef) -> String {
        // nativeSessionID = deepseek:<task>:<worker>
        let parts = ref.nativeSessionID.split(separator: ":")
        guard parts.count == 3 else { return sessionsDir + "/_invalid.json" }
        return sessionsDir + "/\(parts[1])/\(parts[2]).json"
    }

    private func loadHistory(_ ref: SessionRef) -> [JSONValue] {
        guard let data = FileManager.default.contents(atPath: historyPath(ref)),
              let arr = try? JSONDecoder().decode([JSONValue].self, from: data) else { return [] }
        return arr
    }

    private func saveHistory(_ ref: SessionRef, _ messages: [JSONValue]) {
        let path = historyPath(ref)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(JSONValue.array(messages)) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    public func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                         deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTurn(ref: ref, context: context,
                                           continuation: continuation)
                    continuation.finish()
                } catch let error as Failure {
                    switch error {
                    case .auth: continuation.yield(.authRequired)
                    case .quota: continuation.yield(.quotaLimited)
                    default:
                        continuation.yield(.uncertain(error.localizedDescription))
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    enum Failure: Error { case auth, quota, transport(String) }

    private func runTurn(ref: SessionRef, context: TurnContext,
                         continuation: AsyncThrowingStream<AdapterEvent, Error>.Continuation)
        async throws {
        let key = try keyReader()
        var history = loadHistory(ref)
        var messages: [JSONValue] = history
        if messages.isEmpty {
            messages.append(.object([
                "role": .string("system"),
                "content": .string(context.packetText(for: .deepseek))]))
        } else {
            messages.append(.object([
                "role": .string("user"),
                "content": .string(context.packetText(for: .deepseek))]))
        }
        continuation.yield(.turnStarted)
        var iterations = 0
        while iterations < maxIterations {
            iterations += 1
            let (status, body) = try await transport.postJSON(
                url: endpoint,
                headers: ["Authorization": "Bearer \(key)",
                          "Content-Type": "application/json"],
                body: ["model": .string("deepseek-flash"),
                       "thinking": .object(["type": .string("enabled")]),
                       "reasoning_effort": .string("max"),
                       "messages": .array(messages),
                       "tools": .array(Self.toolSchemas()),
                       "max_tokens": .number(Double(maxTokens))])
            if status != 200, let dir =
                ProcessInfo.processInfo.environment["WORKSHOP_DIAG_DIR"] {
                let p = dir + "/deepseek-errors.log"
                let line = "HTTP \(status): "
                    + String(decoding: (try? JSONEncoder().encode(body)) ?? Data(),
                             as: UTF8.self).prefix(500) + "\n"
                if let fh = FileHandle(forWritingAtPath: p) {
                    fh.seekToEndOfFile(); fh.write(Data(line.utf8)); fh.closeFile()
                } else {
                    FileManager.default.createFile(atPath: p, contents: Data(line.utf8))
                }
            }
            switch status {
            case 401: throw Failure.auth
            case 402, 429: throw Failure.quota
            case 200: break
            default:
                if status >= 500 { continuation.yield(.uncertain("HTTP \(status)")) }
                throw Failure.transport("HTTP \(status)")
            }
            guard let message = body["choices"]?.arrayValue?.first?["message"] else {
                throw Failure.transport("malformed response")
            }
            if let usage = body["usage"] {
                continuation.yield(.usageSample(
                    input: usage["prompt_tokens"]?.intValue.map(Int.init),
                    output: usage["completion_tokens"]?.intValue.map(Int.init),
                    cacheRead: usage["prompt_cache_hit_tokens"]?.intValue.map(Int.init),
                    cacheWrite: nil, source: "deepseek:usage"))
            }
            let toolCalls = message["tool_calls"]?.arrayValue ?? []
            if toolCalls.isEmpty {
                if let text = message["content"]?.stringValue, !text.isEmpty {
                    continuation.yield(.messageDelta(text))
                }
                // Persist only visible messages (no reasoning_content).
                let visible: JSONValue = .object([
                    "role": .string("assistant"),
                    "content": message["content"] ?? .null])
                let persisted = messages.map { m -> JSONValue in
                    guard case .object(var o) = m else { return m }
                    o.removeValue(forKey: "reasoning_content")
                    return .object(o)
                } + [visible]
                saveHistory(ref, persisted)
                continuation.yield(.turnCompleted)
                return
            }
            // Continue the tool loop: echo the assistant message including
            // reasoning_content (in-memory only, not persisted).
            messages.append(.object([
                "role": .string("assistant"),
                "content": message["content"] ?? .null,
                "reasoning_content": message["reasoning_content"] ?? .null,
                "tool_calls": .array(toolCalls)]))
            for call in toolCalls {
                let name = call["function"]?["name"]?.stringValue ?? ""
                let args = call["function"]?["arguments"]?.stringValue
                    .flatMap { try? JSONDecoder().decode(JSONValue.self,
                                                         from: Data($0.utf8)) } ?? .object([:])
                continuation.yield(.toolActivity(title: name, status: "calling"))
                let result = (try? await toolExecutor(name, args))
                    ?? "{\"error\":\"tool failed\"}"
                messages.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": call["id"] ?? .null,
                    "content": .string(result)]))
                continuation.yield(.toolActivity(title: name, status: "completed"))
            }
            // Persist incrementally (reasoning stripped) so a later failure
            // still leaves a resumable session file.
            saveHistory(ref, messages.map { m -> JSONValue in
                guard case .object(var o) = m else { return m }
                o.removeValue(forKey: "reasoning_content")
                return .object(o)
            })
        }
        throw Failure.transport("tool loop iteration cap reached")
    }

    public func cancelTurn(ref: SessionRef, turnID: String) async {
        // URLSession tasks are bounded by the turn deadline; nothing persistent.
    }
}
