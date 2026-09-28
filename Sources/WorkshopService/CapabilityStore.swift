import CryptoKit
import Foundation
import WorkshopCore

/// config/capabilities.json: writer-qualification records (G-E5). Read at
/// daemon start, reloaded via workshop.reloadCapabilities, written by
/// `workshop-daemon qualify`. Mode 0600, atomic writes.
public final class CapabilityStore: @unchecked Sendable {
    public static let isolatedWriter = "isolated_writer"

    private let path: String
    private let lock = NSLock()
    private var records: [CapabilityRecord] = []

    public init(path: String) {
        self.path = path
        reload()
    }

    /// Re-read the file (created/updated by `qualify` out of process).
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([CapabilityRecord].self,
                                                      from: data) else {
            records = []
            return
        }
        records = decoded
    }

    public func load() -> [CapabilityRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    /// The qualification record for this identity, or nil when absent or
    /// not qualified.
    public func isQualified(_ identity: QualificationIdentity,
                            capability: String = isolatedWriter) -> CapabilityRecord? {
        record(for: identity, capability: capability).flatMap {
            $0.qualified ? $0 : nil
        }
    }

    /// Any record for the identity (qualified or not) — used for binary
    /// drift advisories.
    public func record(for identity: QualificationIdentity,
                       capability: String = isolatedWriter) -> CapabilityRecord? {
        lock.lock(); defer { lock.unlock() }
        return records.last {
            $0.engineer == identity.engineer && $0.lane == identity.lane
                && $0.capability == capability && $0.model == identity.model
        }
    }

    /// Upsert on (engineer, lane, capability, model); atomic 0600 write.
    public func record(_ record: CapabilityRecord) throws {
        lock.lock()
        records.removeAll {
            $0.engineer == record.engineer && $0.lane == record.lane
                && $0.capability == record.capability && $0.model == record.model
        }
        records.append(record)
        let snapshot = records
        lock.unlock()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        let tmp = path + ".tmp-\(UUID().uuidString)"
        try data.write(to: URL(fileURLWithPath: tmp))
        chmod(tmp, 0o600)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: path),
                                     withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try fm.moveItem(atPath: tmp, toPath: path)
        }
    }

    /// SHA-256 of a file's contents (binary-drift advisory).
    public static func sha256(file path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
