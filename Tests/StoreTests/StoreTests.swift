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
                             "operations", "outbox", "session_bindings", "schema_migrations",
                             "artifacts", "usage_samples", "wakeups", "checkpoints",
                             "task_ingress"] {
                XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
            }
        }
        do {
            // Reopen: migration is idempotent.
            let db = try Database(path: path)
            try Migrations.all.migrate(db)
            let count = try db.query("SELECT COUNT(*) AS c FROM schema_migrations")
                .first?["c"]?.int
            XCTAssertEqual(count, Int64(Migrations.all.migrations.count))
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

final class MigrationV2Tests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-mig-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A v1 database upgrades to v2 with existing rows preserved.
    func testV1ToV2PreservesData() throws {
        let path = dir + "/mig.sqlite"
        do {
            let db = try Database(path: path)
            try Migrator(migrations: [Migrations.v1]).migrate(db)
            try db.execute("""
                INSERT INTO tasks(id, channel, title, brief, phase, state,
                                  created_at, updated_at)
                VALUES('task_v1', 'main', 'old task', 'brief', 'execution',
                       'queued', 't0', 't0')
                """)
            try db.execute("""
                INSERT INTO participants(task_id, engineer_id, membership)
                VALUES('task_v1', 'devin', 'member')
                """)
            try db.execute("""
                INSERT INTO messages(id, task_id, seq, author_kind, kind, body,
                                     delivery_state, created_at, updated_at)
                VALUES('msg_v1', 'task_v1', 1, 'user', 'text', 'hello',
                       'committed', 't0', 't0')
                """)
        }
        do {
            let db = try Database(path: path)
            try Migrator(migrations: [Migrations.v2]).migrate(db)
            let tasks = try db.query("SELECT id FROM tasks")
            XCTAssertEqual(tasks.first?["id"]?.text, "task_v1")
            // New columns exist with defaults.
            let p = try db.query("SELECT last_read_seq FROM participants").first
            XCTAssertEqual(p?["last_read_seq"]?.int, 0)
            let m = try db.query("SELECT structured FROM messages").first
            XCTAssertEqual(m?["structured"], .null)
            // New tables queryable.
            for table in ["artifacts", "usage_samples", "wakeups", "checkpoints"] {
                _ = try db.query("SELECT COUNT(*) AS c FROM \(table)")
            }
        }
    }

    func testV3ToV4PreservesData() throws {
        let path = dir + "/mig34.sqlite"
        do {
            let db = try Database(path: path)
            try Migrator(migrations: [Migrations.v1, Migrations.v2,
                                      Migrations.v3]).migrate(db)
            try db.execute("""
                INSERT INTO tasks(id, channel, title, brief, phase, state,
                                  created_at, updated_at)
                VALUES('task_v3', 'main', 'old task', 'brief', 'execution',
                       'queued', 't0', 't0')
                """)
            try db.execute("""
                INSERT INTO checkpoints(task_id, engineer_id, role, worker_id,
                                        generation, schema_version, content,
                                        created_at)
                VALUES('task_v3', 'devin', 'main', 'main', 0, 1, '{}', 't0')
                """)
        }
        do {
            let db = try Database(path: path)
            try Migrator(migrations: [Migrations.v4]).migrate(db)
            XCTAssertEqual(
                try db.query("SELECT id FROM tasks").first?["id"]?.text,
                "task_v3")
            // v4 columns and tables exist.
            XCTAssertEqual(
                try db.query("SELECT valid FROM checkpoints").first?["valid"]?.int,
                1)
            for table in ["quota_snapshots", "reservations", "leases",
                          "outbox_cursors", "turns"] {
                _ = try db.query("SELECT COUNT(*) AS c FROM \(table)")
            }
            // artifacts.generation added.
            _ = try db.query("SELECT generation FROM artifacts")
        }
    }

    /// A v8 database gains wakeup retry columns at v9; deferred rows are
    /// hidden from pendingWakeups until their backoff expires.
    func testV8ToV9AddsWakeupRetryColumns() throws {
        let path = dir + "/mig89.sqlite"
        do {
            let db = try Database(path: path)
            try Migrator(migrations: [Migrations.v1, Migrations.v2,
                                      Migrations.v3, Migrations.v4,
                                      Migrations.v5, Migrations.v6,
                                      Migrations.v7, Migrations.v8]).migrate(db)
            try db.execute("""
                INSERT INTO tasks(id, channel, title, brief, phase, state,
                                  created_at, updated_at)
                VALUES('task_v8', 'main', 'old task', 'brief', 'execution',
                       'queued', 't0', 't0')
                """)
            try db.execute("""
                INSERT INTO wakeups(task_id, engineer_id, reason, state,
                                    created_at, updated_at)
                VALUES('task_v8', 'kimi', 'mention', 'pending', 't0', 't0')
                """)
        }
        do {
            let db = try Database(path: path)
            try Migrations.all.migrate(db)
            let row = try db.query(
                "SELECT attempt, not_before FROM wakeups").first
            XCTAssertEqual(row?["attempt"]?.int, 0)
            XCTAssertEqual(row?["not_before"], .null)

            let repo = WorkshopRepository(db: db)
            // The migrated row is immediately due.
            let due = try repo.pendingWakeups()
            XCTAssertEqual(due.count, 1)
            // A deferred row is hidden until not_before passes.
            try repo.insertWakeup(taskID: TaskID("task_v8"), engineerID: .kimi,
                                  reason: "mention", triggerSeq: nil,
                                  notBefore: Date().addingTimeInterval(3600),
                                  attempt: 1, at: Date())
            XCTAssertEqual(try repo.pendingWakeups().count, 1)
            let next = try repo.earliestDeferredWakeup(at: Date())
            XCTAssertNotNil(next)
        }
    }

    /// A v9 database gains task_memory at v10; appendTurnRecord keeps only
    /// the newest records per (task, engineer).
    func testV9ToV10AddsTaskMemoryRing() throws {
        let path = dir + "/mig910.sqlite"
        do {
            let db = try Database(path: path)
            try Migrator(migrations: Migrations.all.migrations
                .filter { $0.version <= 9 }).migrate(db)
            try db.execute("""
                INSERT INTO tasks(id, channel, title, brief, phase, state,
                                  created_at, updated_at)
                VALUES('task_v9', 'main', 'old task', 'brief', 'execution',
                       'queued', 't0', 't0')
                """)
        }
        let db = try Database(path: path)
        try Migrations.all.migrate(db)
        XCTAssertTrue(try db.query("""
            SELECT name FROM sqlite_master
            WHERE type='table' AND name='task_memory'
            """).count == 1)

        let repo = WorkshopRepository(db: db)
        for i in 0..<10 {
            try repo.appendTurnRecord(
                taskID: TaskID("task_v9"), engineerID: .kimi,
                TurnRecord(turnID: "t\(i)", endedAt: Date(), reason: "mention",
                           outcome: "completed", postedSeqs: [Int64(i)]))
        }
        let records = try repo.taskMemory(taskID: TaskID("task_v9"),
                                          engineerID: .kimi)
        XCTAssertEqual(records.count, 8)
        XCTAssertEqual(records.first?.turnID, "t2")
        XCTAssertEqual(records.last?.turnID, "t9")
        // Independent key per engineer.
        XCTAssertTrue(try repo.taskMemory(taskID: TaskID("task_v9"),
                                          engineerID: .devin).isEmpty)
        try repo.appendTurnRecord(taskID: TaskID("task_v9"), engineerID: .devin,
                                  TurnRecord(turnID: "d0", endedAt: Date(),
                                             outcome: "silent"))
        XCTAssertEqual(try repo.taskMemory(taskID: TaskID("task_v9"),
                                           engineerID: .devin).count, 1)
        XCTAssertEqual(try repo.taskMemory(taskID: TaskID("task_v9"),
                                           engineerID: .kimi).count, 8)
    }
}
