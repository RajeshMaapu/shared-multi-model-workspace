import Foundation

/// Secret redaction applied to every surface a secret could leak through:
/// tool errors returned to models, systemEvent bodies, exports, diagnostics,
/// and captured adapter stderr (T32, §9.4).
public final class Redactor: @unchecked Sendable {
    public static let shared = Redactor()

    private let lock = NSLock()
    /// Literal secret values registered at runtime (e.g. the resolved
    /// DeepSeek key). Compared only — never logged or persisted.
    private var literals: [String] = []

    private let patterns: [NSRegularExpression] = {
        let sources = [
            #"sk-[A-Za-z0-9_-]{8,}"#,
            #"Bearer\s+\S+"#,
            #"(?i)(api[_-]?key|token|secret)\s*[:=]\s*["']?[^\s"']+"#,
        ]
        return sources.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
    }()

    private init() {}

    /// Register a literal secret value (resolved API key, token). The value
    /// itself is only used for replacement comparisons.
    public func registerSecret(_ value: String) {
        guard !value.isEmpty else { return }
        lock.lock()
        literals.append(value)
        lock.unlock()
    }

    /// True when the text contains a pattern match or a registered literal.
    public func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns where pattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        lock.lock()
        let found = literals.contains { text.contains($0) }
        lock.unlock()
        return found
    }

    /// Replace every match with `***REDACTED***`.
    public func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result, range: range, withTemplate: "***REDACTED***")
        }
        lock.lock()
        for literal in literals {
            result = result.replacingOccurrences(of: literal, with: "***REDACTED***")
        }
        lock.unlock()
        return result
    }
}
