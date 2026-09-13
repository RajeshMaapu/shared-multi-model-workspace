import Foundation

/// Typed wrapper for a task identifier (`task_…`).
public struct TaskID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Typed wrapper for a message identifier (`msg_…`).
public struct MessageID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Typed wrapper for a subtask identifier (`sub_…`).
public struct SubtaskID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// The three Workshop engineers.
public enum EngineerID: String, Codable, CaseIterable, Hashable, Sendable {
    case devin
    case kimi
    case deepseek

    public var displayName: String {
        switch self {
        case .devin: return "Devin Fusion"
        case .kimi: return "Kimi K3"
        case .deepseek: return "DeepSeek V4.1 Flash"
        }
    }

    /// Name of the color token used for this engineer's avatar/identity.
    public var colorToken: String {
        switch self {
        case .devin: return "engineerDevin"
        case .kimi: return "engineerKimi"
        case .deepseek: return "engineerDeepseek"
        }
    }
}

/// Generate a lowercase-UUID id with the given prefix.
public func newID(_ prefix: String) -> String {
    prefix + "_" + UUID().uuidString.lowercased()
}
