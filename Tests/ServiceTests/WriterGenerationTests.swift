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
