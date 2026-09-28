import XCTest
import Foundation
@testable import WorkshopCore
@testable import WorkshopService
@testable import WorkshopStore

final class WriterGenerationTests: XCTestCase {
    func fixture(principal: Principal = .user) async throws -> (String, Database, TaskWorkspace) {
        let root = "/private/tmp/writer-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/base/sub", withIntermediateDirectories: true)
        try Data("base".utf8).write(to: URL(fileURLWithPath: root + "/base/sub/file"))
        let db = try Database(path: root + "/test.sqlite")
        let svc = try CollaborationService(database: db, adapters: [], dispatcherEnabled: false)
        let receipt = try await svc.createTask(CreateTaskRequest(idempotencyKey: UUID().uuidString,
            title: "Writer", objective: "Test", phase: .execution, participants: [.devin]),
            principal: principal)
        let workspace = TaskWorkspace(taskID: receipt.taskID, path: root + "/base")
        try WorkshopRepository(db: db).insertTaskWorkspace(workspace)
        return (root, db, workspace)
    }
    func testSealedSnapshotAndAtomicPromotion() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let lease = try store.begin(task: base, engineer: .devin)
        try Data("proposal".utf8).write(to: URL(fileURLWithPath: lease.path + "/sub/file"))
        let candidate = try store.seal(lease)
        try Data("late stale write".utf8).write(to: URL(fileURLWithPath: lease.path + "/sub/file"))
        XCTAssertEqual(try String(contentsOfFile: candidate.path + "/sub/file"), "proposal")
        try store.promote(candidate, verifiedDigest: candidate.digest)
        XCTAssertEqual(try WorkshopRepository(db: db).taskWorkspace(base.taskID)?.path, candidate.path)
        XCTAssertThrowsError(try store.promote(candidate, verifiedDigest: candidate.digest))
        let reopened = try Database(path: home + "/test.sqlite")
        try WriterGenerations(db: reopened, home: home).recover()
        XCTAssertEqual(try WorkshopRepository(db: reopened).taskWorkspace(base.taskID)?.path, candidate.path)
    }
    func testSupersededWriterAndRecoveryCannotPromote() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let old = try store.begin(task: base, engineer: .devin)
        let candidate = try store.seal(old)
        let next = try store.begin(task: base, engineer: .kimi)
        XCTAssertThrowsError(try store.promote(candidate, verifiedDigest: candidate.digest))
        let newer = try store.seal(next)
        try store.recover()
        XCTAssertThrowsError(try store.promote(newer, verifiedDigest: newer.digest))
        XCTAssertEqual(try WorkshopRepository(db: db).taskWorkspace(base.taskID)?.path, base.path)
    }
    func testPeerDiscussionCannotSupersedeOwner() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let owner = try store.begin(task: base, engineer: .devin)
        let peer = try store.begin(task: base, engineer: .kimi, authoritative: false)
        let review = try store.seal(peer)
        XCTAssertThrowsError(try store.promote(review, verifiedDigest: review.digest))
        let candidate = try store.seal(owner)
        try store.promote(candidate, verifiedDigest: candidate.digest)
    }

    func testPeerReviewAndOwnerRevisionSeeSealedProposalWithoutPromotion() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let owner = try store.begin(task: base, engineer: .devin)
        try "proposal v1".write(toFile: owner.path + "/sub/file", atomically: true, encoding: .utf8)
        let first = try store.seal(owner)

        let peer = try store.begin(task: base, engineer: .kimi, authoritative: false)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"), "proposal v1")
        XCTAssertEqual(try String(contentsOfFile: base.path + "/sub/file"), "base")
        let peerOutput = try store.seal(peer)
        XCTAssertThrowsError(try store.promote(peerOutput, verifiedDigest: peerOutput.digest))

        let revision = try store.begin(task: base, engineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: revision.path + "/sub/file"), "proposal v1")
        XCTAssertThrowsError(try store.promote(first, verifiedDigest: first.digest))
    }

    func testOwnerDiscussionRevisionSeedsOwnerAndPeerButNeverPromotesIt() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let first = try store.begin(task: base, engineer: .devin)
        try "first".write(toFile: first.path + "/sub/file", atomically: true, encoding: .utf8)
        _ = try store.seal(first)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false, seedEngineer: .devin)
        try "revised".write(toFile: discussion.path + "/sub/file", atomically: true, encoding: .utf8)
        let reviewOnly = try store.seal(discussion)
        XCTAssertThrowsError(try store.promote(reviewOnly, verifiedDigest: reviewOnly.digest))

        let peer = try store.begin(task: base, engineer: .kimi,
                                   authoritative: false, seedEngineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"), "revised")
        _ = try store.seal(peer)
        let staleDiscussion = try store.begin(task: base, engineer: .devin,
                                              authoritative: false, seedEngineer: .devin)
        try "stale".write(toFile: staleDiscussion.path + "/sub/file",
                             atomically: true, encoding: .utf8)
        _ = try store.seal(staleDiscussion)
        try store.pinReviewSeed(taskID: base.taskID, engineer: .devin,
                                generationID: discussion.id,
                                verifiedDigest: reviewOnly.digest)
        let revision = try store.begin(task: base, engineer: .devin,
                                       seedEngineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: revision.path + "/sub/file"), "revised")
        XCTAssertEqual(try String(contentsOfFile: base.path + "/sub/file"), "base")
    }

    func testChangedOwnerDiscussionAutomaticallySeedsReviewWithoutPromotion() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let first = try store.begin(task: base, engineer: .devin)
        try "first".write(toFile: first.path + "/sub/file", atomically: true, encoding: .utf8)
        _ = try store.seal(first)

        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false, seedEngineer: .devin,
                                         reviewSeedOwner: true)
        try "revised".write(toFile: discussion.path + "/sub/file",
                             atomically: true, encoding: .utf8)
        let revised = try store.seal(discussion)
        let pin = try db.query("SELECT generation_id,digest FROM writer_seed_pins WHERE task_id=?",
                               [.text(base.taskID.rawValue)]).first
        XCTAssertEqual(pin?["generation_id"]?.text, discussion.id)
        XCTAssertEqual(pin?["digest"]?.text, revised.digest)

        // A later no-edit discussion must keep the revised proposal selected.
        let noEdit = try store.begin(task: base, engineer: .devin,
                                     authoritative: false, seedEngineer: .devin,
                                     reviewSeedOwner: true)
        _ = try store.seal(noEdit)
        let pinAfterNoEdit = try db.query(
            "SELECT generation_id FROM writer_seed_pins WHERE task_id=?",
            [.text(base.taskID.rawValue)]).first
        XCTAssertEqual(pinAfterNoEdit?["generation_id"]?.text, discussion.id)

        let peer = try store.begin(task: base, engineer: .kimi,
                                   authoritative: false, seedEngineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"), "revised")
        let ownerRevision = try store.begin(task: base, engineer: .devin,
                                             seedEngineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: ownerRevision.path + "/sub/file"), "revised")
        XCTAssertEqual(try String(contentsOfFile: base.path + "/sub/file"), "base")
        XCTAssertThrowsError(try store.promote(revised, verifiedDigest: revised.digest))
    }

    func testPeerCanReadOnlyVerifiedReviewFileWithoutFilesystemAccess() async throws {
        let (home, db, base) = try await fixture()
        try "private baseline".write(toFile: base.path + "/sub/unchanged",
                                         atomically: true, encoding: .utf8)
        let store = WriterGenerations(db: db, home: home)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false, seedEngineer: .devin,
                                         reviewSeedOwner: true)
        try "revision".write(toFile: discussion.path + "/sub/file",
                               atomically: true, encoding: .utf8)
        let sealed = try store.seal(discussion)
        let service = try CollaborationService(database: db, adapters: [],
                                               dispatcherEnabled: false, homeDir: home)
        let result = try await service.readReviewFile(taskID: base.taskID,
                                                      path: "sub/file", principal: .user)
        XCTAssertEqual(result["content"]?.stringValue, "revision")
        XCTAssertEqual(result["snapshot_digest"]?.stringValue, sealed.digest)
        XCTAssertEqual(result["generation_id"]?.stringValue, discussion.id)
        XCTAssertThrowsError(try store.promote(sealed, verifiedDigest: sealed.digest))
        do {
            _ = try await service.readReviewFile(taskID: base.taskID,
                                                  path: "../test.sqlite", principal: .user)
            XCTFail("Traversal must be rejected")
        } catch { }
        do {
            _ = try await service.readReviewFile(taskID: base.taskID,
                                                  path: "sub/file", principal: .engineer(.kimi))
            XCTFail("Non-participant must be rejected")
        } catch { }
        do {
            _ = try await service.readReviewFile(taskID: base.taskID,
                                                  path: "sub/unchanged", principal: .user)
            XCTFail("Unchanged source file must not be exposed")
        } catch { }
        try "tamper".write(toFile: sealed.path + "/sub/file", atomically: true,
                              encoding: .utf8)
        do {
            _ = try await service.readReviewFile(taskID: base.taskID,
                                                  path: "sub/file", principal: .user)
            XCTFail("Changed snapshot must be rejected")
        } catch { }
    }

    func testCodexCanSelectAndReadOnlyItsOwnDigestVerifiedReviewSeed() async throws {
        let (home, db, base) = try await fixture(principal: .codex)
        let service = try CollaborationService(database: db, adapters: [],
                                               dispatcherEnabled: false, homeDir: home)
        let subtask = try await service.getTask(base.taskID).subtasks[0]
        _ = try await service.claimForTest(subtaskID: subtask.id, owner: .devin,
                                           expectedGeneration: 0)
        let store = WriterGenerations(db: db, home: home)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false, seedEngineer: .devin)
        try "revision".write(toFile: discussion.path + "/sub/file",
                              atomically: true, encoding: .utf8)
        let sealed = try store.seal(discussion)
        let args: JSONValue = .object([
            "task_id": .string(base.taskID.rawValue),
            "engineer": .string("devin"),
            "generation_id": .string(discussion.id),
            "verified_digest": .string(sealed.digest),
        ])
        let selected = try await service.callTool("workshop_select_review_seed",
                                                   args: args, principal: .codex)
        XCTAssertEqual(selected["selected"], .bool(true))
        let read = try await service.callTool("workshop_read_review_file",
                                              args: .object([
                                                "task_id": .string(base.taskID.rawValue),
                                                "path": .string("sub/file"),
                                              ]), principal: .codex)
        XCTAssertEqual(read["content"]?.stringValue, "revision")
        XCTAssertEqual(read["snapshot_digest"]?.stringValue, sealed.digest)
        XCTAssertEqual(try String(contentsOfFile: base.path + "/sub/file"), "base")
        XCTAssertThrowsError(try store.promote(sealed, verifiedDigest: sealed.digest))

        do {
            _ = try await service.callTool("workshop_select_review_seed",
                                           args: .object([
                                            "task_id": .string(base.taskID.rawValue),
                                            "engineer": .string("devin"),
                                            "generation_id": .string(discussion.id),
                                            "verified_digest": .string("wrong"),
                                           ]), principal: .codex)
            XCTFail("Digest mismatch must be rejected")
        } catch { }
    }

    func testCodexCannotSelectOrReadReviewSeedOfUserOriginTask() async throws {
        let (home, db, base) = try await fixture()
        let service = try CollaborationService(database: db, adapters: [],
                                               dispatcherEnabled: false, homeDir: home)
        for tool in ["workshop_select_review_seed", "workshop_read_review_file"] {
            var arguments: [String: JSONValue] = ["task_id": .string(base.taskID.rawValue)]
            if tool == "workshop_select_review_seed" {
                arguments["engineer"] = .string("devin")
                arguments["generation_id"] = .string("unknown")
                arguments["verified_digest"] = .string("unknown")
            } else {
                arguments["path"] = .string("sub/file")
            }
            do {
                _ = try await service.callTool(tool,
                                               args: .object(arguments),
                                               principal: .codex)
                XCTFail("Codex may not access a user-origin review seed")
            } catch let error as WorkshopRPCError {
                XCTAssertEqual(error.rpcCode, -32005)
            }
        }
    }

    func testOlderOwnerDiscussionCannotReplaceNewerReviewSeed() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let old = try store.begin(task: base, engineer: .devin,
                                  authoritative: false, reviewSeedOwner: true)
        let newer = try store.begin(task: base, engineer: .devin,
                                    authoritative: false, reviewSeedOwner: true)
        try "newer".write(toFile: newer.path + "/sub/file",
                           atomically: true, encoding: .utf8)
        _ = try store.seal(newer)
        try "older".write(toFile: old.path + "/sub/file",
                           atomically: true, encoding: .utf8)
        _ = try store.seal(old)
        let pin = try db.query("SELECT generation_id FROM writer_seed_pins WHERE task_id=?",
                               [.text(base.taskID.rawValue)]).first
        XCTAssertEqual(pin?["generation_id"]?.text, newer.id)
    }

    /// A pin older than the newest authoritative snapshot is stale: the
    /// reviewer must see the revision's files, not the pinned proposal.
    func testNewerSealedRevisionSupersedesOlderReviewPin() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let first = try store.begin(task: base, engineer: .devin)
        try "one".write(toFile: first.path + "/sub/file",
                        atomically: true, encoding: .utf8)
        _ = try store.seal(first)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false,
                                         reviewSeedOwner: true)
        try "pinned".write(toFile: discussion.path + "/sub/file",
                           atomically: true, encoding: .utf8)
        let pinned = try store.seal(discussion)
        try store.pinReviewSeed(taskID: base.taskID, engineer: .devin,
                                generationID: discussion.id,
                                verifiedDigest: pinned.digest)
        // The owner then seals a NEWER authoritative revision.
        let revision = try store.begin(task: base, engineer: .devin)
        try "revised".write(toFile: revision.path + "/sub/file",
                            atomically: true, encoding: .utf8)
        try "revised.txt".write(toFile: revision.path + "/revised.txt",
                                atomically: true, encoding: .utf8)
        _ = try store.seal(revision)
        // The reviewer seeds from the sealed revision, not the stale pin.
        let peer = try store.begin(task: base, engineer: .kimi,
                                   authoritative: false, seedEngineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"),
                       "revised")
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/revised.txt"),
                       "revised.txt")
        XCTAssertNil(peer.expectedPinGenerationID)
        // The stale pin is left in place but must not be replaced by a
        // discussion seal either.
        _ = try store.seal(peer)
        let pin = try db.query(
            "SELECT generation_id FROM writer_seed_pins WHERE task_id=?",
            [.text(base.taskID.rawValue)]).first
        XCTAssertEqual(pin?["generation_id"]?.text, discussion.id)
    }

    /// A pin newer than every authoritative snapshot still wins.
    func testPinNewerThanLatestSealedSnapshotStillWins() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let first = try store.begin(task: base, engineer: .devin)
        try "first".write(toFile: first.path + "/sub/file",
                          atomically: true, encoding: .utf8)
        _ = try store.seal(first)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false,
                                         reviewSeedOwner: true)
        try "revised".write(toFile: discussion.path + "/sub/file",
                            atomically: true, encoding: .utf8)
        let pinned = try store.seal(discussion)
        try store.pinReviewSeed(taskID: base.taskID, engineer: .devin,
                                generationID: discussion.id,
                                verifiedDigest: pinned.digest)
        let peer = try store.begin(task: base, engineer: .kimi,
                                   authoritative: false, seedEngineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"),
                       "revised")
        XCTAssertEqual(peer.expectedPinGenerationID, discussion.id)
    }

    /// A superseded sealed snapshot is still an immutable authoritative
    /// snapshot and remains the seed when no pin is set.
    func testSupersededSealedSnapshotStillSeedsReview() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let first = try store.begin(task: base, engineer: .devin)
        try "one".write(toFile: first.path + "/sub/file",
                        atomically: true, encoding: .utf8)
        _ = try store.seal(first)
        let second = try store.begin(task: base, engineer: .devin)
        try "two".write(toFile: second.path + "/sub/file",
                        atomically: true, encoding: .utf8)
        _ = try store.seal(second)
        // A third authoritative begin supersedes the second sealed row.
        let third = try store.begin(task: base, engineer: .devin)
        XCTAssertEqual(try String(contentsOfFile: third.path + "/sub/file"),
                       "two")
        XCTAssertEqual(try db.query(
            "SELECT state FROM writer_generations WHERE id=?",
            [.text(second.id)]).first?["state"]?.text, "superseded")
        // The peer still seeds from the newest (now superseded) snapshot.
        let peer = try store.begin(task: base, engineer: .kimi,
                                   authoritative: false)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"),
                       "two")
    }

    func testChangedSealedProposalCannotSeedReview() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let proposal = try store.seal(store.begin(task: base, engineer: .devin))
        try "tampered".write(toFile: proposal.path + "/sub/file", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.begin(task: base, engineer: .kimi, authoritative: false))
    }

    func testInterruptedSealedProposalRemainsReadableAfterRestart() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let owner = try store.begin(task: base, engineer: .devin)
        try "review me".write(toFile: owner.path + "/sub/file", atomically: true, encoding: .utf8)
        let proposal = try store.seal(owner)
        try store.recover()
        XCTAssertThrowsError(try store.promote(proposal, verifiedDigest: proposal.digest))
        let peer = try store.begin(task: base, engineer: .kimi, authoritative: false)
        XCTAssertEqual(try String(contentsOfFile: peer.path + "/sub/file"), "review me")
    }

    func testGenerationCredentialRevocationAndTaskScope() async throws {
        let (home, db, base) = try await fixture()
        let service = try CollaborationService(database: db, adapters: [], dispatcherEnabled: false, homeDir: home)
        let store = WriterGenerations(db: db, home: home)
        let lease = try store.begin(task: base, engineer: .devin)
        let token = try String(contentsOfFile: (lease.path as NSString).deletingLastPathComponent + "/token")
        let principal = try await service.authenticate(token: token)
        XCTAssertEqual(principal, .engineer(.devin))
        try await service.authorizeWriterRequest(token: token, method: "workshop_post_message",
            params: .object(["task_id": .string(base.taskID.rawValue)]))
        do {
            try await service.authorizeWriterRequest(token: token, method: "workshop_post_message",
                params: .object(["task_id": .string("task_other")]))
            XCTFail("Cross-task capability accepted")
        } catch {}
        try store.recover()
        do { _ = try await service.authenticate(token: token); XCTFail("Revoked writer authenticated") } catch {}
    }

    func testChangedCandidateAndWrongVerificationAreRejected() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let candidate = try store.seal(store.begin(task: base, engineer: .devin))
        XCTAssertThrowsError(try store.promote(candidate, verifiedDigest: "wrong"))
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: candidate.path + "/sub/file"))
        XCTAssertThrowsError(try store.promote(candidate, verifiedDigest: candidate.digest))
    }
    func testSymlinkHardlinkAndSpecialFileRejected() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        for kind in ["symlink", "hardlink", "fifo"] {
            let lease = try store.begin(task: base, engineer: .devin)
            let target = lease.path + "/bad"
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: "/etc/passwd")
            case "hardlink": try FileManager.default.linkItem(atPath: lease.path + "/sub/file", toPath: target)
            default: XCTAssertEqual(mkfifo(target, 0o600), 0)
            }
            XCTAssertThrowsError(try store.seal(lease))
        }
    }

    /// The Workshop-written MCP config carries a bearer token: excluded from
    /// copies and digests at top level only; nested .devin content survives.
    func testSafeTreeExcludesTopLevelMCPConfig() throws {
        let root = "/private/tmp/safetree-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let src = root + "/src"
        try FileManager.default.createDirectory(
            atPath: src + "/.devin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: src + "/sub/.devin", withIntermediateDirectories: true)
        try "a".write(toFile: src + "/a.txt", atomically: true, encoding: .utf8)
        try "cfg".write(toFile: src + "/.devin/config.json", atomically: true,
                        encoding: .utf8)
        try "token-one".write(toFile: src + "/.devin/mcp_config.local.json",
                              atomically: true, encoding: .utf8)
        try "nested".write(toFile: src + "/sub/.devin/mcp_config.local.json",
                           atomically: true, encoding: .utf8)

        let dst = root + "/dst"
        _ = try SafeTree.copy(from: src, to: dst)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dst + "/.devin/mcp_config.local.json"))
        XCTAssertEqual(try String(contentsOfFile: dst + "/.devin/config.json"),
                       "cfg")
        XCTAssertEqual(
            try String(contentsOfFile: dst + "/sub/.devin/mcp_config.local.json"),
            "nested")

        let d1 = try SafeTree.digest(src)
        try "token-two".write(toFile: src + "/.devin/mcp_config.local.json",
                              atomically: true, encoding: .utf8)
        XCTAssertEqual(try SafeTree.digest(src), d1)
        try "b".write(toFile: src + "/a.txt", atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try SafeTree.digest(src), d1)
    }
}

extension WriterGenerationTests {
    /// Pre-redesign snapshots were digested with `.devin/mcp_config.local.json`
    /// included. A stored legacy digest verifies via the fallback, upgrades the
    /// row in place, and still refuses a tampered snapshot.
    func testLegacySnapshotDigestUpgradesOnBegin() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let snap = home + "/writer-snapshots/legacy-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: snap + "/.devin",
                                                withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: snap + "/file.txt"))
        try Data("{\"token\":\"x\"}".utf8).write(to: URL(fileURLWithPath:
            snap + "/.devin/mcp_config.local.json"))
        let legacy = try SafeTree.legacyDigest(snap)
        XCTAssertNotEqual(legacy, try SafeTree.digest(snap))
        let genID = UUID().uuidString
        try db.execute("""
            INSERT INTO writer_generations(id,task_id,engineer,path,base_path,
                state,snapshot_path,digest) VALUES(?,?,?,?,?,?,?,?)
            """, [.text(genID), .text(base.taskID.rawValue), .text("devin"),
                  .text(home + "/writer-runs/legacy/workspace"), .text(base.path),
                  .text("interrupted"), .text(snap), .text(legacy)])
        let lease = try store.begin(task: base, engineer: .devin)
        let row = try db.query(
            "SELECT digest FROM writer_generations WHERE id=?",
            [.text(genID)]).first
        XCTAssertEqual(row?["digest"]?.text, try SafeTree.digest(snap))
        XCTAssertEqual(try String(contentsOfFile: lease.path + "/file.txt"), "old")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: lease.path + "/.devin/mcp_config.local.json"))
        // A snapshot whose content changed under BOTH digest schemes throws.
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: snap + "/file.txt"))
        XCTAssertThrowsError(try store.begin(task: base, engineer: .devin)) { error in
            XCTAssertTrue("\(error)".contains("snapshot changed"))
        }
    }

    /// Insert a generation row plus its on-disk run/snapshot directories.
    @discardableResult
    private func insertGeneration(db: Database, home: String, id: String,
                                  task: String, engineer: String,
                                  state: String, basePath: String,
                                  snapshot: Bool = true)
        throws -> (run: String, snap: String?) {
        let run = home + "/writer-runs/" + id
        try FileManager.default.createDirectory(
            atPath: run + "/workspace", withIntermediateDirectories: true)
        try Data("tok".utf8).write(to: URL(fileURLWithPath: run + "/token"))
        var snap: String?
        if snapshot {
            snap = home + "/writer-snapshots/snap-" + id
            try FileManager.default.createDirectory(
                atPath: snap! + "/sub", withIntermediateDirectories: true)
            try Data("s".utf8).write(to: URL(fileURLWithPath: snap! + "/sub/f"))
        }
        try db.execute("""
            INSERT INTO writer_generations(id,task_id,engineer,path,base_path,
                state,snapshot_path,digest) VALUES(?,?,?,?,?,?,?,?)
            """, [.text(id), .text(task), .text(engineer),
                  .text(run + "/workspace"), .text(basePath), .text(state),
                  snap.map { SQLiteValue.text($0) } ?? .null,
                  .text("digest-" + id)])
        return (run, snap)
    }

    private func prunedAt(_ db: Database, _ id: String) throws -> String? {
        try db.query("SELECT pruned_at FROM writer_generations WHERE id=?",
                     [.text(id)]).first?["pruned_at"]?.text
    }

    /// Decision D-e: unprotected superseded/review-only rows beyond the
    /// newest three lose their directories and are stamped `pruned_at`;
    /// pins, sealed/writing/accepted rows, the task-workspace snapshot and
    /// the newest three rows are untouched.
    func testPruneDeletesOnlyUnprotectedGenerations() async throws {
        let (home, db, base) = try await fixture()
        let svc = try CollaborationService(database: db, adapters: [],
                                           dispatcherEnabled: false)
        let taskB = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "B", objective: "B",
            phase: .execution, participants: [.devin]),
            principal: .user).taskID
        let store = WriterGenerations(db: db, home: home)
        // Task A: pin + sealed + accepted-as-workspace protected; the lone
        // superseded row is the only deletable one (and it is older than
        // the newest three).
        let a1 = try insertGeneration(db: db, home: home, id: "a1",
            task: base.taskID.rawValue, engineer: "kimi",
            state: "review_only", basePath: base.path)
        let a2 = try insertGeneration(db: db, home: home, id: "a2",
            task: base.taskID.rawValue, engineer: "devin",
            state: "superseded", basePath: base.path)
        let a3 = try insertGeneration(db: db, home: home, id: "a3",
            task: base.taskID.rawValue, engineer: "devin",
            state: "sealed", basePath: base.path)
        // The accepted generation's snapshot IS the task workspace.
        let a4run = home + "/writer-runs/a4"
        try FileManager.default.createDirectory(
            atPath: a4run + "/workspace", withIntermediateDirectories: true)
        try db.execute("""
            INSERT INTO writer_generations(id,task_id,engineer,path,base_path,
                state,snapshot_path,digest) VALUES(?,?,?,?,?,?,?,?)
            """, [.text("a4"), .text(base.taskID.rawValue), .text("devin"),
                  .text(a4run + "/workspace"), .text(base.path),
                  .text("accepted"), .text(base.path), .text("digest-a4")])
        try db.execute("""
            INSERT INTO writer_seed_pins(task_id,engineer,generation_id,
                digest,created_at) VALUES(?,?,?,?,?)
            """, [.text(base.taskID.rawValue), .text("kimi"), .text("a1"),
                  .text("digest-a1"), .text("t0")])
        // A fifth row pushes a2 outside the newest-three window.
        let a5 = try insertGeneration(db: db, home: home, id: "a5",
            task: base.taskID.rawValue, engineer: "devin",
            state: "review_only", basePath: base.path)
        // Task B: four rows — the oldest superseded is deletable; the
        // other three are inside the newest-three window (incl. writing).
        let b1 = try insertGeneration(db: db, home: home, id: "b1",
            task: taskB.rawValue, engineer: "devin",
            state: "superseded", basePath: base.path)
        let b2 = try insertGeneration(db: db, home: home, id: "b2",
            task: taskB.rawValue, engineer: "devin",
            state: "superseded", basePath: base.path)
        let b3 = try insertGeneration(db: db, home: home, id: "b3",
            task: taskB.rawValue, engineer: "devin",
            state: "review_only", basePath: base.path)
        let b4 = try insertGeneration(db: db, home: home, id: "b4",
            task: taskB.rawValue, engineer: "kimi",
            state: "writing", basePath: base.path, snapshot: false)

        let report = try store.prune()
        XCTAssertEqual(report.deletedDirs, 4)  // a2 + b1, run + snapshot
        XCTAssertGreaterThan(report.bytes, 0)
        for id in ["a2", "b1"] {
            XCTAssertNotNil(try prunedAt(db, id), "\(id) must be pruned")
        }
        for dir in [a2.run, a2.snap, b1.run, b1.snap] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir!),
                           "\(dir!) should be deleted")
        }
        // Protected: pin, sealed, accepted-as-workspace, newest-three,
        // writing.
        for id in ["a1", "a3", "a4", "a5", "b2", "b3", "b4"] {
            XCTAssertNil(try prunedAt(db, id), "\(id) must be protected")
        }
        for dir in [a1.run, a1.snap, a3.run, a3.snap, a5.run, a5.snap,
                    a4run, b2.run, b2.snap, b3.run, b3.snap, b4.run] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir!),
                          "\(dir!) should remain")
        }
        // A pruned row keeps its digest and paths for history.
        let row = try db.query("""
            SELECT digest,path,snapshot_path FROM writer_generations
            WHERE id='a2'
            """).first
        XCTAssertEqual(row?["digest"]?.text, "digest-a2")
        XCTAssertEqual(row?["path"]?.text, a2.run + "/workspace")
    }

    /// A run dir that is a symlink (or resolves outside the roots) is
    /// refused, logged and left for an operator — never unlinked through.
    func testPruneRefusesSymlinkedRunDir() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        // Five superseded rows: the oldest two are beyond the newest
        // three and deletable; give the first's run dir a symlink
        // pointing outside the roots.
        let s1 = try insertGeneration(db: db, home: home, id: "s1",
            task: base.taskID.rawValue, engineer: "devin",
            state: "superseded", basePath: base.path)
        let s2 = try insertGeneration(db: db, home: home, id: "s2",
            task: base.taskID.rawValue, engineer: "devin",
            state: "superseded", basePath: base.path)
        for id in ["s3", "s4", "s5"] {
            _ = try insertGeneration(db: db, home: home, id: id,
                task: base.taskID.rawValue, engineer: "devin",
                state: "superseded", basePath: base.path)
        }
        let outside = home + "/outside-target"
        try FileManager.default.createDirectory(atPath: outside,
                                                withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: s1.run)
        try FileManager.default.createSymbolicLink(
            atPath: s1.run, withDestinationPath: outside)
        var logs: [String] = []
        let report = try store.prune(log: { logs.append($0) })
        // s1 refused entirely; s2 (also beyond newest-three) deleted.
        XCTAssertEqual(report.deletedDirs, 2)
        XCTAssertTrue(logs.contains { $0.contains("refused") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside),
                      "symlink target must be untouched")
        XCTAssertNil(try prunedAt(db, "s1"))
        XCTAssertNotNil(try prunedAt(db, "s2"))
    }

    /// maxDeletesPerPass bounds one pass; a second pass finishes the row.
    func testPruneRespectsMaxDeletesPerPass() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        for i in 1...6 {
            _ = try insertGeneration(db: db, home: home, id: "d\(i)",
                task: base.taskID.rawValue, engineer: "devin",
                state: "superseded", basePath: base.path)
        }
        // d1..d3 are beyond the newest three → 6 directories total.
        let first = try store.prune(maxDeletesPerPass: 3)
        XCTAssertEqual(first.deletedDirs, 3)
        XCTAssertNotNil(try prunedAt(db, "d1"))   // run+snap fully removed
        XCTAssertNil(try prunedAt(db, "d2"))      // snapshot deferred
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home + "/writer-snapshots/snap-d2"))
        let second = try store.prune(maxDeletesPerPass: 20)
        XCTAssertNotNil(try prunedAt(db, "d2"))
        XCTAssertNotNil(try prunedAt(db, "d3"))
        XCTAssertEqual(second.deletedDirs, 3)
    }

    /// readReviewFile serves the current effective seed: once a newer sealed
    /// revision supersedes a stale pin, reviewers read the revision's bytes.
    func testReadReviewFileServesNewestAuthoritativeOverStalePin() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false,
                                         seedEngineer: .devin)
        try "stale".write(toFile: discussion.path + "/sub/file",
                          atomically: true, encoding: .utf8)
        let pinnedCandidate = try store.seal(discussion)
        try store.pinReviewSeed(taskID: base.taskID, engineer: .devin,
                                generationID: discussion.id,
                                verifiedDigest: pinnedCandidate.digest)
        let revision = try store.begin(task: base, engineer: .devin)
        try "revised".write(toFile: revision.path + "/sub/file",
                            atomically: true, encoding: .utf8)
        let sealedRevision = try store.seal(revision)
        let service = try CollaborationService(database: db, adapters: [],
                                               dispatcherEnabled: false,
                                               homeDir: home)
        let result = try await service.readReviewFile(
            taskID: base.taskID, path: "sub/file", principal: .user)
        XCTAssertEqual(result["content"]?.stringValue, "revised")
        XCTAssertEqual(result["generation_id"]?.stringValue, revision.id)
        XCTAssertEqual(result["snapshot_digest"]?.stringValue,
                       sealedRevision.digest)
    }

    /// Pinning a snapshot older than the newest sealed revision is refused:
    /// it would serve reviewers pre-edit bytes.
    func testSelectReviewSeedRefusesSnapshotOlderThanSealedRevision() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        // The discussion snapshot is sealed BEFORE the newer revision, so
        // pinning it afterwards would serve reviewers stale bytes.
        let older = try store.begin(task: base, engineer: .devin,
                                    authoritative: false,
                                    seedEngineer: .devin)
        let staleSeal = try store.seal(older)
        let revision = try store.begin(task: base, engineer: .devin)
        try "revised".write(toFile: revision.path + "/sub/file",
                            atomically: true, encoding: .utf8)
        _ = try store.seal(revision)
        XCTAssertThrowsError(
            try store.pinReviewSeed(taskID: base.taskID, engineer: .devin,
                                    generationID: older.id,
                                    verifiedDigest: staleSeal.digest)) { error in
            XCTAssertTrue(error.localizedDescription
                .contains("supersedes this snapshot; pin refused"),
                          error.localizedDescription)
        }
    }

    /// The effective-seed change is announced exactly once per task.
    func testReviewSeedChangeAnnouncedExactlyOnce() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let discussion = try store.begin(task: base, engineer: .devin,
                                         authoritative: false,
                                         seedEngineer: .devin)
        try "stale".write(toFile: discussion.path + "/sub/file",
                          atomically: true, encoding: .utf8)
        let pinnedCandidate = try store.seal(discussion)
        try store.pinReviewSeed(taskID: base.taskID, engineer: .devin,
                                generationID: discussion.id,
                                verifiedDigest: pinnedCandidate.digest)
        let revision = try store.begin(task: base, engineer: .devin)
        try "revised".write(toFile: revision.path + "/sub/file",
                            atomically: true, encoding: .utf8)
        _ = try store.seal(revision)
        let service = try CollaborationService(database: db, adapters: [],
                                               dispatcherEnabled: false,
                                               homeDir: home)
        _ = try await service.readReviewFile(
            taskID: base.taskID, path: "sub/file", principal: .user)
        _ = try await service.readReviewFile(
            taskID: base.taskID, path: "sub/file", principal: .user)
        let events = try db.query("""
            SELECT body FROM messages WHERE task_id=? AND kind='system_event'
              AND body LIKE 'Review seed is now sealed revision%'
            """, [.text(base.taskID.rawValue)])
        XCTAssertEqual(events.count, 1,
                       events.map { $0["body"]?.text ?? "?" }.joined())
        let body = events.first?["body"]?.text ?? ""
        XCTAssertTrue(body.contains(String(revision.id.prefix(8))), body)
        XCTAssertTrue(body.contains("superseded"), body)
    }

    /// getTask exposes the effective seed so reviewers can cite it.
    func testGetTaskReportsReviewSeed() async throws {
        let (home, db, base) = try await fixture()
        let store = WriterGenerations(db: db, home: home)
        let revision = try store.begin(task: base, engineer: .devin)
        try "revised".write(toFile: revision.path + "/sub/file",
                            atomically: true, encoding: .utf8)
        let sealed = try store.seal(revision)
        let service = try CollaborationService(database: db, adapters: [],
                                               dispatcherEnabled: false,
                                               homeDir: home)
        let before = try await service.getTask(base.taskID)
        let sub = before.subtasks[0]
        _ = try await service.claimForTest(subtaskID: sub.id,
                                           owner: .devin,
                                           expectedGeneration: sub.generation)
        let detail = try await service.getTask(base.taskID)
        XCTAssertEqual(detail.reviewSeed?.generationID, revision.id)
        XCTAssertEqual(detail.reviewSeed?.digest, sealed.digest)
        XCTAssertEqual(detail.reviewSeed?.source, "authoritative")
    }
}
