import Foundation
import WorkshopCore
import WorkshopService

/// HTTP transport abstraction so tests can stub the wire without URLProtocol.
public protocol HTTPTransport: Sendable {
    func postJSON(url: URL, headers: [String: String], body: [String: JSONValue])
        async throws -> (status: Int, body: JSONValue)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }
    public func postJSON(url: URL, headers: [String: String],
                         body: [String: JSONValue]) async throws -> (status: Int, body: JSONValue) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        return (status, json)
    }
    /// Cancels in-flight requests (T23 cancellation acknowledgement).
    public func cancelAll() async {
        await session.allTasks.forEach { $0.cancel() }
    }
}

/// Compatibility spelling: the DeepSeek tool loop is generalized into the
/// managed runtime lane (decision D-b). `DeepSeekAdapter` stays the same
/// concrete type — a managed runtime bound to the DeepSeek provider preset.
public typealias DeepSeekAdapter = ManagedRuntimeAdapter

public extension ManagedRuntimeAdapter {
    /// DeepSeek compatibility initializer: `keyReader` returns the API key at
    /// request time (credential reference); `toolExecutor` runs a workshop
    /// tool and returns result JSON text. `model` is verified against the
    /// provider (and its echoed runtime name captured) before the first real
    /// turn request.
    convenience init(transport: HTTPTransport = URLSessionHTTPTransport(),
                     sessionsDir: String,
                     endpoint: URL = URL(string: "https://api.deepseek.com/v1/chat/completions")!,
                     model: String = ManagedRuntimeAdapter.defaultModel,
                     keyReader: @escaping @Sendable () throws -> String,
                     toolExecutor: @escaping @Sendable (String, JSONValue) async throws -> String) {
        self.init(engineer: .deepseek,
                  provider: .deepseek(model: model, endpoint: endpoint),
                  transport: transport,
                  sessionsDir: sessionsDir,
                  keyReader: keyReader,
                  workshopToolExecutor: toolExecutor,
                  localTools: false)
    }

    /// Targeted TOML section/key scanner for credential references — NOT a
    /// general parser. Reads `[providers, deepseek, api_key]` from
    /// ~/.kimi-code/config.toml by default.
    static func readCredential(path: String = NSHomeDirectory() + "/.kimi-code/config.toml",
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

    /// Tool schemas sent to DeepSeek mirror the workshop bridge tools.
    static func toolSchemas() -> [JSONValue] {
        catalogToolSchemas()
    }

    /// Bounded balance probe (§10): GET /user/balance → a quota snapshot with
    /// remaining = total_balance and unit = currency. Availability only; no
    /// account ids are read or stored. 10 s timeout.
    static func balanceProbe(home: String, observedAt: Date) async -> QuotaSnapshot? {
        guard let key = try? readCredential() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let info = json["balance_infos"]?.arrayValue?.first,
              let balance = info["total_balance"]?.stringValue else {
            return QuotaSnapshot(bucket: "deepseek", remaining: "unknown",
                                 source: "deepseek:/user/balance",
                                 observedAt: observedAt, availability: "unknown")
        }
        let currency = info["currency"]?.stringValue
        let available: Bool
        if case .bool(let b) = info["is_available"] { available = b } else { available = true }
        return QuotaSnapshot(bucket: "deepseek", remaining: balance,
                             unit: currency, source: "deepseek:/user/balance",
                             observedAt: observedAt,
                             availability: available ? "available" : "limited")
    }
}
