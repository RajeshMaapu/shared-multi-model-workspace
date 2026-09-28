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
        public let sourceDigest: String?
        public let expectedPinGenerationID: String?
        public let reviewSeedOwner: Bool

        public init(id: String, taskID: TaskID, engineer: EngineerID,
                    path: String, basePath: String, sourceDigest: String? = nil,
                    expectedPinGenerationID: String? = nil,
                    reviewSeedOwner: Bool = false) {
            self.id = id
            self.taskID = taskID
            self.engineer = engineer
            self.path = path
            self.basePath = basePath
            self.sourceDigest = sourceDigest
            self.expectedPinGenerationID = expectedPinGenerationID
            self.reviewSeedOwner = reviewSeedOwner
        }
    }
    public struct Candidate: Equatable, Sendable {
        public let lease: Lease
        public let path: String
        public let digest: String
    }
    private let db: Database
    private let home: String
    public init(db: Database, home: String) { self.db = db; self.home = home }

    /// Verify a stored snapshot digest, upgrading pre-redesign digests.
    /// Old snapshots were digested with `.devin/mcp_config.local.json`
    /// included; when the legacy digest matches the stored value the content
    /// is unchanged and the row is migrated to the new digest.
    @discardableResult
    public func verifyOrUpgradeDigest(snapshotPath: String, storedDigest: String,
                                      generationID: String) throws -> String {
        let current = try SafeTree.digest(snapshotPath)
        if current == storedDigest { return current }
        guard try SafeTree.legacyDigest(snapshotPath) == storedDigest else {
            throw WorkshopError.invalidRequest(
                "Sealed writer snapshot changed; review required")
        }
        try db.transaction {
            try db.execute("""
                UPDATE writer_generations SET digest=? WHERE id=? AND digest=?
                """, [.text(current), .text(generationID), .text(storedDigest)])
            try db.execute("""
                UPDATE writer_seed_pins SET digest=? WHERE generation_id=? AND digest=?
                """, [.text(current), .text(generationID), .text(storedDigest)])
        }
        return current
    }

    /// The effective fenced review seed for a task — the single rule used by
    /// generation seeding, review-file reads, read-only grants and pins.
    public struct ReviewSeed: Sendable, Equatable {
        public enum Source: String, Sendable {
            case pin, authoritative, reviewOnly = "review_only"
        }
        public let generationID: String
        public let snapshotPath: String
        public let digest: String
        public let source: Source
    }

    /// A pinned review seed wins unless a NEWER authoritative snapshot
    /// exists (a sealed revision supersedes a stale pin); otherwise the
    /// newest snapshot wins across authoritative and discussion proposals.
    /// `seedEngineer` scopes the pin and the candidates to that owner; when
    /// nil the pin belongs to `requester` and candidates are unscoped.
    public func currentReviewSeed(taskID: TaskID, requester: EngineerID,
                                  seedEngineer: EngineerID? = nil) throws -> ReviewSeed? {
        let pin = try db.query("""
            SELECT g.rowid AS growid, g.snapshot_path,g.digest,p.generation_id FROM writer_seed_pins p
            JOIN writer_generations g ON g.id=p.generation_id
            WHERE p.task_id=? AND p.engineer=? AND p.digest=g.digest
              AND g.task_id=p.task_id AND g.engineer=p.engineer
              AND g.state='review_only' AND g.snapshot_path IS NOT NULL
            """, [.text(taskID.rawValue),
                  .text((seedEngineer ?? requester).rawValue)]).first
        let ownerFilter = seedEngineer == nil ? "" : " AND engineer=?"
        var parameters: [SQLiteValue?] = [.text(taskID.rawValue)]
        if let seedEngineer { parameters.append(.text(seedEngineer.rawValue)) }
        // Newest snapshot of an authoritative generation, even when that
        // generation has since been superseded — the snapshot itself is
        // still immutable. A pin older than this is stale (reviewers would
        // otherwise verify against files the revision already replaced).
        let newestAuthoritative = try db.query("SELECT id,rowid,snapshot_path,digest FROM writer_generations WHERE task_id=?\(ownerFilter) AND state IN ('sealed','superseded','accepted','interrupted') AND snapshot_path IS NOT NULL ORDER BY rowid DESC LIMIT 1", parameters).first
        let newestReviewOnly = try db.query("SELECT id,rowid,snapshot_path,digest FROM writer_generations WHERE task_id=?\(ownerFilter) AND state='review_only' AND snapshot_path IS NOT NULL ORDER BY rowid DESC LIMIT 1", parameters).first
        var seed: Row?
        var source = ReviewSeed.Source.authoritative
        let pinRowid = pin?["growid"]?.int ?? 0
        let authRowid = newestAuthoritative?["rowid"]?.int ?? 0
        if let pin, pinRowid >= authRowid {
            seed = pin
            source = .pin
        } else {
            for candidate in [newestAuthoritative, newestReviewOnly] {
                guard let candidate,
                      let rowid = candidate["rowid"]?.int,
                      rowid > (seed?["rowid"]?.int ?? seed?["growid"]?.int ?? 0)
                else { continue }
                seed = candidate
                source = candidate["id"]?.text == newestAuthoritative?["id"]?.text
                    ? .authoritative : .reviewOnly
            }
        }
        guard let row = seed else { return nil }
        guard let snapshot = row["snapshot_path"]?.text,
              let digest = row["digest"]?.text,
              let generationID = row["id"]?.text ?? row["generation_id"]?.text else {
            throw WorkshopError.invalidRequest("Sealed writer snapshot changed; review required")
        }
        let upgraded = try verifyOrUpgradeDigest(snapshotPath: snapshot,
                                                 storedDigest: digest,
                                                 generationID: generationID)
        return ReviewSeed(generationID: generationID, snapshotPath: snapshot,
                          digest: upgraded, source: source)
    }

    /// Select an immutable owner discussion snapshot for subsequent fenced
    /// review and revision turns. It remains non-promotable.
    public func pinReviewSeed(taskID: TaskID, engineer: EngineerID,
                              generationID: String, verifiedDigest: String) throws {
        guard let row = try db.query("""
            SELECT rowid,snapshot_path,digest FROM writer_generations
            WHERE id=? AND task_id=? AND engineer=? AND state='review_only'
            """, [.text(generationID), .text(taskID.rawValue),
                  .text(engineer.rawValue)]).first,
              let snapshot = row["snapshot_path"]?.text,
              let digest = row["digest"]?.text,
              digest == verifiedDigest else {
            throw WorkshopError.invalidRequest("Review seed identity or digest mismatch")
        }
        // A sealed revision newer than this snapshot already supersedes it;
        // pinning it would serve reviewers stale bytes.
        let authRowid = try db.query("""
            SELECT MAX(rowid) AS m FROM writer_generations
            WHERE task_id=? AND engineer=?
              AND state IN ('sealed','superseded','accepted','interrupted')
              AND snapshot_path IS NOT NULL
            """, [.text(taskID.rawValue), .text(engineer.rawValue)])
            .first?["m"]?.int ?? 0
        if authRowid > (row["rowid"]?.int ?? 0) {
            throw WorkshopError.invalidRequest(
                "a newer sealed revision supersedes this snapshot; pin refused")
        }
        let upgraded = try verifyOrUpgradeDigest(snapshotPath: snapshot,
                                                 storedDigest: digest,
                                                 generationID: generationID)
        try db.execute("""
            INSERT INTO writer_seed_pins(task_id,engineer,generation_id,digest,created_at)
            VALUES(?,?,?,?,?) ON CONFLICT(task_id) DO UPDATE SET
            engineer=excluded.engineer,generation_id=excluded.generation_id,
            digest=excluded.digest,created_at=excluded.created_at
            """, [.text(taskID.rawValue), .text(engineer.rawValue),
                  .text(generationID), .text(upgraded),
                  .text(WorkshopTime.string(Date()))])
    }

    public func begin(task: TaskWorkspace, engineer: EngineerID,
                      authoritative: Bool = true,
                      seedEngineer: EngineerID? = nil,
                      reviewSeedOwner: Bool = false) throws -> Lease {
        let id = UUID().uuidString.lowercased()
        let path = home + "/writer-runs/" + id + "/workspace"
        try FileManager.default.createDirectory(atPath: home + "/writer-runs/" + id,
                                               withIntermediateDirectories: true)
        // Both review and revision turns need the latest proposal's files.
        // Verify the immutable snapshot before copying it into a fresh fenced
        // generation; this does not promote it to the shared task workspace.
        var source = task.path
        var expectedPin: String?
        if let seed = try currentReviewSeed(taskID: task.taskID,
                                            requester: engineer,
                                            seedEngineer: seedEngineer) {
            source = seed.snapshotPath
            if seed.source == .pin { expectedPin = seed.generationID }
        }
        let sourceDigest = try SafeTree.copy(from: source, to: path)
        let token = (0..<32).map { _ in UInt8.random(in: .min ... .max) }.map { String(format: "%02x", $0) }.joined()
        let tokenPath = (path as NSString).deletingLastPathComponent + "/token"
        try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        chmod(tokenPath, 0o600)
        let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        try initializeRepository(at: path, generation: id)
        let lease = Lease(id: id, taskID: task.taskID, engineer: engineer,
                          path: path, basePath: task.path,
                          sourceDigest: sourceDigest,
                          expectedPinGenerationID: expectedPin,
                          reviewSeedOwner: !authoritative && reviewSeedOwner)
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
            if state == "discussion", lease.reviewSeedOwner,
               lease.sourceDigest != digest {
                // A changed owner proposal is immediately readable in fresh
                // fenced review workspaces. Never promote it to the accepted
                // task workspace, and never replace a pin changed mid-turn.
                let currentPin = try db.query(
                    "SELECT generation_id FROM writer_seed_pins WHERE task_id=?",
                    [.text(lease.taskID.rawValue)]).first?["generation_id"]?.text
                if currentPin == lease.expectedPinGenerationID {
                    try db.execute("""
                        INSERT INTO writer_seed_pins(task_id,engineer,generation_id,digest,created_at)
                        VALUES(?,?,?,?,?) ON CONFLICT(task_id) DO UPDATE SET
                        engineer=excluded.engineer,generation_id=excluded.generation_id,
                        digest=excluded.digest,created_at=excluded.created_at
                        """, [.text(lease.taskID.rawValue), .text(lease.engineer.rawValue),
                              .text(lease.id), .text(digest),
                              .text(WorkshopTime.string(Date()))])
                }
            }
        }
        return Candidate(lease: lease, path: path, digest: digest)
    }

    /// Caller must be a trusted verifier acting on this exact sealed digest.
    /// Recording a model's completion message is deliberately not sufficient.
    public func promote(_ candidate: Candidate, verifiedDigest: String) throws {
        guard verifiedDigest == candidate.digest else {
            throw WorkshopError.invalidRequest("Verified snapshot digest mismatch")
        }
        // Upgrades a legacy stored digest; a changed snapshot still throws.
        let effective = try verifyOrUpgradeDigest(snapshotPath: candidate.path,
                                                  storedDigest: candidate.digest,
                                                  generationID: candidate.lease.id)
        try db.transaction {
            let row = try requireCurrent(candidate.lease, state: "sealed")
            guard row["snapshot_path"]?.text == candidate.path,
                  row["digest"]?.text == effective else {
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

    /// Retention sweep (decision D-e, retention option b): delete the run
    /// and snapshot directories of generations that are no longer useful —
    /// superseded, interrupted, review-only and stale discussion rows —
    /// while protecting live material. A row is never deleted when it is
    /// `writing`/`sealed`/`accepted`, is the pinned review seed, is the
    /// newest authoritative snapshot for its task (the same set `begin`
    /// seeds from), backs `task_workspaces.path`, or is among the
    /// `keepPerTask` newest rows for its task. Directories are deleted
    /// only when their canonical path still lives under
    /// `home/writer-runs` or `home/writer-snapshots`; anything else is
    /// refused and logged. Rows touched get `pruned_at` stamped.
    @discardableResult
    public func prune(keepPerTask: Int = 3, maxDeletesPerPass: Int = 20,
                      log: (String) -> Void = { _ in })
        throws -> (deletedDirs: Int, bytes: Int64) {
        let fm = FileManager.default
        let canonicalRuns = canonicalPath(home + "/writer-runs")
        let canonicalSnaps = canonicalPath(home + "/writer-snapshots")
        var report = (deletedDirs: 0, bytes: Int64(0))
        let rows = try db.query("""
            SELECT id,task_id,state,snapshot_path,rowid FROM writer_generations
            WHERE pruned_at IS NULL ORDER BY task_id, rowid
            """)
        // Per-task bookkeeping.
        var protectedIDs = Set<String>()        // ids that must never prune
        var protectedNewest = [String: Set<String>]() // task -> newest N ids
        for row in rows {
            guard let id = row["id"]?.text,
                  let state = row["state"]?.text
            else { continue }
            if ["writing", "sealed", "accepted"].contains(state) {
                protectedIDs.insert(id)
            }
        }
        let pins = try db.query("SELECT task_id,generation_id FROM writer_seed_pins")
        for pin in pins {
            if let g = pin["generation_id"]?.text { protectedIDs.insert(g) }
        }
        // Newest authoritative snapshot per task (same rule `begin` uses).
        for row in try db.query("""
            SELECT id FROM (
                SELECT id, task_id, rowid,
                       MAX(rowid) OVER (PARTITION BY task_id) AS m
                FROM writer_generations
                WHERE state IN ('sealed','superseded','accepted','interrupted')
                  AND snapshot_path IS NOT NULL)
            WHERE rowid = m
            """) {
            if let id = row["id"]?.text { protectedIDs.insert(id) }
        }
        // Snapshots backing the live task workspaces.
        for row in try db.query("SELECT task_id,path FROM task_workspaces") {
            guard let task = row["task_id"]?.text,
                  let path = row["path"]?.text else { continue }
            for match in try db.query("""
                SELECT id FROM writer_generations
                WHERE task_id=? AND snapshot_path=?
                """, [.text(task), .text(path)]) {
                if let id = match["id"]?.text { protectedIDs.insert(id) }
            }
        }
        // Newest N rows per task.
        var byTask: [String: [(id: String, rowid: Int64, state: String)]] = [:]
        for row in rows {
            guard let id = row["id"]?.text, let task = row["task_id"]?.text,
                  let state = row["state"]?.text, let rowid = row["rowid"]?.int
            else { continue }
            byTask[task, default: []].append((id, rowid, state))
        }
        for (task, list) in byTask {
            let newest = Set(list.sorted { $0.rowid > $1.rowid }
                .prefix(keepPerTask).map(\.id))
            protectedNewest[task] = newest
        }
        func canonicalPath(_ p: String) -> String {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(p, &buf) != nil ? String(cString: buf)
                : (p as NSString).standardizingPath
        }
        func dirBytes(_ p: String) -> Int64 {
            var total: Int64 = 0
            guard let en = fm.enumerator(atPath: p) else { return 0 }
            for case let name as String in en {
                let full = p + "/" + name
                if let attrs = try? fm.attributesOfItem(atPath: full),
                   let size = attrs[.size] as? Int64 { total += size }
            }
            return total
        }
        /// Delete a directory only when the canonical path stays under the
        /// expected parent and the top-level entry is not a symlink.
        func removeDir(_ p: String, under canonicalParent: String,
                       label: String) -> Bool {
            let canonical = canonicalPath(p)
            guard canonical.hasPrefix(canonicalParent + "/") else {
                log("prune refused \(label): \(canonical) outside \(canonicalParent)")
                return false
            }
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else {
                log("prune refused \(label): symlink or unreadable \(p)")
                return false
            }
            let bytes = dirBytes(canonical)
            do {
                try fm.removeItem(atPath: canonical)
                report.deletedDirs += 1
                report.bytes += bytes
                return true
            } catch {
                log("prune failed \(label): \(error.localizedDescription)")
                return false
            }
        }
        let deletable: Set<String> =
            ["superseded", "interrupted", "review_only", "discussion"]
        for (task, list) in byTask where report.deletedDirs < maxDeletesPerPass {
            for item in list where report.deletedDirs < maxDeletesPerPass {
                guard deletable.contains(item.state),
                      !protectedIDs.contains(item.id),
                      !(protectedNewest[task]?.contains(item.id) ?? false)
                else { continue }
                let row = rows.first(where: { $0["id"]?.text == item.id })!
                let runDir = home + "/writer-runs/" + item.id
                var refused = false
                if fm.fileExists(atPath: runDir),
                   report.deletedDirs < maxDeletesPerPass {
                    refused = !removeDir(runDir, under: canonicalRuns,
                                         label: "run \(item.id)")
                }
                // A refused run dir keeps the whole row untouched.
                if !refused, let snap = row["snapshot_path"]?.text,
                   fm.fileExists(atPath: snap),
                   report.deletedDirs < maxDeletesPerPass {
                    _ = removeDir(snap, under: canonicalSnaps,
                                  label: "snapshot \(item.id)")
                }
                // Mark pruned only when nothing remains; a refused or
                // deferred directory is retried on the next pass.
                let snapLeft = (row["snapshot_path"]?.text).map {
                    fm.fileExists(atPath: $0) } ?? false
                if !fm.fileExists(atPath: runDir), !snapLeft {
                    try db.execute("""
                        UPDATE writer_generations SET pruned_at=? WHERE id=?
                        """, [.text(WorkshopTime.string(Date())), .text(item.id)])
                }
            }
        }
        return report
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
        try digest(path, includeMCPConfig: false)
    }
    /// Pre-redesign snapshots were digested with `.devin/mcp_config.local.json`
    /// included; used only to recognize (then upgrade) those stored digests.
    public static func legacyDigest(_ path: String) throws -> String {
        try digest(path, includeMCPConfig: true)
    }
    private static func digest(_ path: String, includeMCPConfig: Bool) throws -> String {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        var budget = (bytes: 0, files: 0)
        var hash = SHA256()
        try walk(fd, -1, prefix: "", budget: &budget, hash: &hash,
                 includeMCPConfig: includeMCPConfig)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func walk(_ src: Int32, _ dst: Int32, prefix: String,
                             budget: inout (bytes: Int, files: Int), hash: inout SHA256,
                             includeMCPConfig: Bool = false) throws {
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
            // The Workshop-written MCP config carries the bearer token; it must
            // never enter a sealed snapshot or perturb the digest. Top-level
            // only — nested .devin dirs and .devin/config.json are legitimate.
            if !includeMCPConfig, prefix == ".devin/", name == "mcp_config.local.json" { continue }
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
                try walk(fd, output, prefix: relative + "/", budget: &budget, hash: &hash,
                         includeMCPConfig: includeMCPConfig)
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
