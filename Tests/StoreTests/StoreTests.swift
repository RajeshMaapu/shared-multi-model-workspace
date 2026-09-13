import XCTest
@testable import WorkshopStore
@testable import WorkshopCore

final class StoreTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-store-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testMigrationAppliesAndIsIdempotent() throws {
        let path = dir + "/test.sqlite"
        do {
            let db = try Database(path: path)
            try Migrations.all.migrate(db)
            let tables = try db.query(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
                .compactMap { $0["name"]?.text }
            for expected in ["tasks", "participants", "messages", "subtasks",
                             "operations", "outbox", "session_bindings", "schema_migrations"] {
                XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
            }
        }
        do {
            // Reopen: migration is idempotent.
            let db = try Database(path: path)
            try Migrations.all.migrate(db)
            let count = try db.query("SELECT COUNT(*) AS c FROM schema_migrations")
                .first?["c"]?.int
            XCTAssertEqual(count, 1)
        }
    }

    func testPragmas() throws {
        let db = try Database(path: dir + "/p.sqlite")
        XCTAssertEqual(try db.pragma("journal_mode"), "wal")
        XCTAssertEqual(try db.pragma("synchronous"), "2")
        XCTAssertEqual(try db.pragma("foreign_keys"), "1")
    }

    func testForeignKeyViolationThrows() throws {
        let db = try Database(path: dir + "/fk.sqlite")
        try Migrations.all.migrate(db)
        let repo = WorkshopRepository(db: db)
        XCTAssertThrowsError(try repo.insertMessage(Message(
            id: MessageID(newID("msg")), taskID: TaskID("task_missing"), seq: 1,
            author: .user, kind: .text, body: "orphan",
            deliveryState: .committed, createdAt: Date(), updatedAt: Date())))
    }

    func testCASClaim() throws {
        let db = try Database(path: dir + "/cas.sqlite")
        try Migrations.all.migrate(db)
        let repo = WorkshopRepository(db: db)
        let task = WorkshopTask(id: TaskID(newID("task")), channel: "projects",
                                title: "T", brief: "B", phase: .execution,
                                state: .queued, createdAt: Date(), updatedAt: Date())
        try repo.insertTask(task)
        let sub = Subtask(id: SubtaskID(newID("sub")), taskID: task.id, title: "T",
                          state: .ready, createdAt: Date(), updatedAt: Date())
        try repo.insertSubtask(sub)
        let lease = Date().addingTimeInterval(60)
        XCTAssertTrue(try repo.claimSubtask(sub.id, owner: .devin, expectedGeneration: 0,
                                          leaseExpiresAt: lease, at: Date()))
        XCTAssertFalse(try repo.claimSubtask(sub.id, owner: .kimi, expectedGeneration: 0,
                                           leaseExpiresAt: lease, at: Date()))
        XCTAssertEqual(try repo.subtask(sub.id)?.generation, 1)
        XCTAssertEqual(try repo.subtask(sub.id)?.ownerID, .devin)
    }

    func testTransactionRollback() throws {
        let db = try Database(path: dir + "/tx.sqlite")
        try Migrations.all.migrate(db)
        let repo = WorkshopRepository(db: db)
        let task = WorkshopTask(id: TaskID(newID("task")), channel: "projects",
                                title: "T", brief: "B", phase: .execution,
                                state: .queued, createdAt: Date(), updatedAt: Date())
        XCTAssertThrowsError(try repo.db.transaction {
            try repo.insertTask(task)
            throw StoreError.stepFailed("boom")
        })
        XCTAssertNil(try repo.task(task.id))
    }
}
