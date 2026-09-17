import Foundation
import CryptoKit
import Darwin
import WorkshopCore
import WorkshopStore

/// Owned by the service actor. Workers never receive this database or a
/// promotion capability. Their writable directories are expendable proposals;
/// accepted snapshots are separate daemon-owned directories.
public final class WriterGenerations {
    public struct Lease: Equatable, Sendable {
        public let id: String
        public let taskID: TaskID
        public let engineer: EngineerID
        public let path: String
        public let basePath: String
    }
    public struct Candidate: Equatable, Sendable {
        public let lease: Lease
        public let path: String
        public let digest: String
    }
    private let db: Database
    private let home: String
    public init(db: Database, home: String) { self.db = db; self.home = home }

    public func begin(task: TaskWorkspace, engineer: EngineerID, authoritative: Bool = true) throws -> Lease {
        let id = UUID().uuidString.lowercased()
        let path = home + "/writer-runs/" + id + "/workspace"
        try FileManager.default.createDirectory(atPath: home + "/writer-runs/" + id,
                                               withIntermediateDirectories: true)
        _ = try SafeTree.copy(from: task.path, to: path)
        let token = (0..<32).map { _ in UInt8.random(in: .min ... .max) }.map { String(format: "%02x", $0) }.joined()
        let tokenPath = (path as NSString).deletingLastPathComponent + "/token"
        try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        chmod(tokenPath, 0o600)
        let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        try initializeRepository(at: path, generation: id)
        let lease = Lease(id: id, taskID: task.taskID, engineer: engineer,
                          path: path, basePath: task.path)
        try db.transaction {
            if authoritative { try db.execute("UPDATE writer_generations SET state='superseded' WHERE task_id=? AND state IN ('writing','sealed')", [.text(task.taskID.rawValue)]) }
            try db.execute("INSERT INTO writer_generations(id,task_id,engineer,path,base_path,state,token_hash) VALUES(?,?,?,?,?,?,?)", [.text(id), .text(task.taskID.rawValue), .text(engineer.rawValue), .text(path), .text(task.path), .text(authoritative ? "writing" : "discussion"), .text(tokenHash)])
        }
        return lease
    }

    private func initializeRepository(at path: String, generation: String) throws {
        for args in [["init", "--template=", "--initial-branch=codex/writer-" + generation],
                     ["add", "--all"],
                     ["-c", "user.name=Workshop", "-c", "user.email=workshop@localhost", "commit", "--allow-empty", "-m", "Writer generation baseline"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: path)
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": path,
                                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
            process.waitUntilExit(); deadline.cancel()
            guard process.terminationStatus == 0 else { throw WorkshopError.invalidRequest("Writer repository initialization failed") }
        }
    }

    /// Copy into a fresh private directory before accepting any verification.
    /// An old writer can continue modifying its own tree, never this candidate.
    public func seal(_ lease: Lease) throws -> Candidate {
        let initial = try db.query("SELECT state FROM writer_generations WHERE id=?", [.text(lease.id)]).first?["state"]?.text
        let state = initial == "discussion" ? "discussion" : "writing"
        try requireCurrent(lease, state: state)
        let path = home + "/writer-snapshots/" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: home + "/writer-snapshots", withIntermediateDirectories: true)
        let digest = try SafeTree.copy(from: lease.path, to: path)
        try db.transaction {
            try requireCurrent(lease, state: state)
            try db.execute("UPDATE writer_generations SET state=?,snapshot_path=?,digest=? WHERE id=?", [.text(state == "writing" ? "sealed" : "review_only"), .text(path), .text(digest), .text(lease.id)])
        }
        return Candidate(lease: lease, path: path, digest: digest)
    }

    /// Caller must be a trusted verifier acting on this exact sealed digest.
    /// Recording a model's completion message is deliberately not sufficient.
    public func promote(_ candidate: Candidate, verifiedDigest: String) throws {
        guard verifiedDigest == candidate.digest,
              try SafeTree.digest(candidate.path) == candidate.digest else {
            throw WorkshopError.invalidRequest("Verified snapshot digest mismatch")
        }
        try db.transaction {
            let row = try requireCurrent(candidate.lease, state: "sealed")
            guard row["snapshot_path"]?.text == candidate.path,
                  row["digest"]?.text == verifiedDigest else {
                throw WorkshopError.invalidRequest("Candidate identity mismatch")
            }
            // Compare-and-swap the logical task workspace. No multi-file in-place
            // overwrite: crash before commit keeps the old pointer, after commit
            // preserves the complete fsynced candidate.
            try db.execute("UPDATE task_workspaces SET path=?,state='snapshot' WHERE task_id=? AND path=?", [.text(candidate.path), .text(candidate.lease.taskID.rawValue), .text(candidate.lease.basePath)])
            guard db.changes() == 1 else { throw WorkshopError.invalidRequest("Task base changed; review required") }
            try db.execute("UPDATE writer_generations SET state='accepted' WHERE id=?", [.text(candidate.lease.id)])
        }
    }

    /// On daemon restart, previous processes may still write their proposals.
    /// They cannot seal/promote after this durable revocation. Do not delete them.
    public func recover() throws {
        try db.execute("UPDATE writer_generations SET state='interrupted' WHERE state IN ('writing','sealed','discussion')")
    }

    @discardableResult
    private func requireCurrent(_ lease: Lease, state: String) throws -> Row {
        guard let row = try db.query("SELECT * FROM writer_generations WHERE id=?", [.text(lease.id)]).first,
              row["state"]?.text == state, row["task_id"]?.text == lease.taskID.rawValue,
              row["engineer"]?.text == lease.engineer.rawValue,
              row["path"]?.text == lease.path, row["base_path"]?.text == lease.basePath else {
            throw WorkshopError.invalidRequest("Stale writer generation")
        }
        return row
    }
}

/// Descriptor-relative copying: reject symlinks, hardlinks and special files;
/// do not follow worker-controlled Git config, hooks, filters or external refs.
/// Bounds turn oversized output into a reviewable failure, never a partial acceptance.
public enum SafeTree {
    private static let maximumBytes = 256 * 1024 * 1024
    private static let maximumFiles = 20_000
    private static func failure() -> WorkshopError { .invalidRequest("Unsafe, changing or oversized writer tree; files preserved") }
    public static func copy(from source: String, to destination: String) throws -> String {
        guard mkdir(destination, 0o700) == 0 else { throw failure() }
        let src = open(source, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let dst = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard src >= 0, dst >= 0 else {
            if src >= 0 { close(src) }; if dst >= 0 { close(dst) }; throw failure()
        }
        defer { close(src); close(dst) }
        var budget = (bytes: 0, files: 0)
        var hash = SHA256()
        try walk(src, dst, prefix: "", budget: &budget, hash: &hash)
        guard fsync(dst) == 0 else { throw failure() }
        let parent = open((destination as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw failure() }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func digest(_ path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        var budget = (bytes: 0, files: 0)
        var hash = SHA256()
        try walk(fd, -1, prefix: "", budget: &budget, hash: &hash)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func walk(_ src: Int32, _ dst: Int32, prefix: String,
                             budget: inout (bytes: Int, files: Int), hash: inout SHA256) throws {
        guard let directory = fdopendir(dup(src)) else { throw failure() }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.lowercased() == ".git" { continue }
            names.append(name)
            guard names.count <= maximumFiles else { throw failure() }
        }
        for name in names.sorted() {
            budget.files += 1
            guard budget.files <= maximumFiles, prefix.count < 4096 else { throw failure() }
            let fd = openat(src, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }; defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0 else { throw failure() }
            let kind = before.st_mode & S_IFMT
            let relative = prefix + name
            // JSON framing avoids ambiguous path/content concatenations.
            hash.update(data: try JSONEncoder().encode([relative, String(kind), String(kind == S_IFREG ? before.st_mode & 0o111 : 0)]))
            if kind == S_IFDIR {
                var output: Int32 = -1
                if dst >= 0 {
                    guard mkdirat(dst, name, 0o700) == 0 else { throw failure() }
                    output = openat(dst, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard output >= 0 else { throw failure() }
                }
                defer { if output >= 0 { close(output) } }
                try walk(fd, output, prefix: relative + "/", budget: &budget, hash: &hash)
                if output >= 0, fsync(output) != 0 { throw failure() }
            } else if kind == S_IFREG, before.st_nlink == 1 {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    guard count >= 0 else { throw failure() }
                    if count == 0 { break }
                    budget.bytes += count
                    guard budget.bytes <= maximumBytes else { throw failure() }
                    data.append(contentsOf: buffer.prefix(count))
                }
                var after = stat()
                guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw failure() }
                hash.update(data: try JSONEncoder().encode(data.count))
                hash.update(data: data)
                if dst >= 0 {
                    let out = openat(dst, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600 | (before.st_mode & 0o111))
                    guard out >= 0 else { throw failure() }; defer { close(out) }
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let n = write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            guard n > 0 else { throw failure() }; offset += n
                        }
                    }
                    guard fsync(out) == 0 else { throw failure() }
                }
            } else { throw failure() }
        }
    }
}
