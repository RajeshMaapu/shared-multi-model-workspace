import XCTest
import Foundation
@testable import WorkshopCore
@testable import WorkshopService
@testable import WorkshopStore

final class WriterGenerationTests: XCTestCase {
    func fixture() async throws -> (String, Database, TaskWorkspace) {
        let root = "/private/tmp/writer-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/base/sub", withIntermediateDirectories: true)
        try Data("base".utf8).write(to: URL(fileURLWithPath: root + "/base/sub/file"))
        let db = try Database(path: root + "/test.sqlite")
        let svc = try CollaborationService(database: db, adapters: [], dispatcherEnabled: false)
        let receipt = try await svc.createTask(CreateTaskRequest(idempotencyKey: UUID().uuidString,
            title: "Writer", objective: "Test", phase: .execution, participants: [.devin]))
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
}
