import Foundation
import CryptoKit

/// Safe user-visible activity only; never raw provider payloads or reasoning.
public struct WorkActivity: Codable, Equatable, Sendable {
    public var seq: Int64
    public var taskID: TaskID
    public var turnID: String
    public var engineer: EngineerID
    public var kind: String
    public var title: String
    public var status: String
    public var callID: String?
    public var createdAt: Date

    public static func safeTitle(_ value: String) -> String {
        let clean = Redactor.shared.redact(value).replacingOccurrences(
            of: #"(?i)(password|passwd|authorization|cookie)\s*[:=]\s*[^\s]+"#,
            with: "[redacted]", options: .regularExpression)
        return String(clean.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(240))
    }

    public init(seq: Int64 = 0, taskID: TaskID, turnID: String, engineer: EngineerID,
                kind: String, title: String, status: String, callID: String? = nil, createdAt: Date) {
        self.seq = seq; self.taskID = taskID; self.turnID = turnID; self.engineer = engineer
        self.kind = ["tool", "lifecycle", "message", "permission", "status"].contains(kind) ? kind : "status"; self.title = Self.safeTitle(title)
        self.status = ["started", "pending", "in_progress", "completed", "failed", "denied", "cancelled", "uncertain", "updated"].contains(status) ? status : "updated"
        // Correlation identifier stays opaque and bounded; no raw command/input/output.
        self.callID = callID.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        self.createdAt = createdAt
    }
}
