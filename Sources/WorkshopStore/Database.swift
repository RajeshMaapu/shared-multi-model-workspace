import Foundation
import SQLite3
import WorkshopCore

public enum StoreError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case constraintViolation(String)
    case notInTransaction
    case invalidData(String)
}

/// SQLite value for typed binding/results.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case text(String)
    case integer(Int64)

    public var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var int: Int64? {
        if case .integer(let i) = self { return i }
        return nil
    }
}

public typealias Row = [String: SQLiteValue]

/// Thin SQLite wrapper. NOT thread-safe: must be owned by a single actor.
public final class Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h { sqlite3_close(h) }
            throw StoreError.openFailed(msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit { sqlite3_close(handle) }

    /// Read a pragma value (e.g. journal_mode, synchronous, foreign_keys).
    public func pragma(_ name: String) throws -> String? {
        guard let row = try query("PRAGMA \(name)").first else { return nil }
        if let v = row[name] { return v.text ?? v.int.map(String.init) }
        return row.values.first?.text ?? row.values.first?.int.map(String.init)
    }

    /// Number of rows changed by the last statement.
    public func changes() -> Int {
        Int(sqlite3_changes(handle))
    }

    public func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    public func execute(_ sql: String, _ bindings: [SQLiteValue?] = []) throws {
        _ = try run(sql, bindings)
    }

    @discardableResult
    public func query(_ sql: String, _ bindings: [SQLiteValue?] = []) throws -> [Row] {
        try run(sql, bindings)
    }

    private func run(_ sql: String, _ bindings: [SQLiteValue?]) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.prepareFailed(errmsg())
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in bindings.enumerated() {
            let i = Int32(index + 1)
            let rc: Int32
            switch value {
            case .none, .some(.null):
                rc = sqlite3_bind_null(stmt, i)
            case .some(.text(let s)):
                rc = sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .some(.integer(let n)):
                rc = sqlite3_bind_int64(stmt, i, n)
            }
            guard rc == SQLITE_OK else { throw StoreError.prepareFailed(errmsg()) }
        }

        var rows: [Row] = []
        let columnCount = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row = Row()
                for c in 0..<columnCount {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER:
                        row[name] = .integer(sqlite3_column_int64(stmt, c))
                    case SQLITE_NULL:
                        row[name] = .null
                    default:
                        row[name] = sqlite3_column_text(stmt, c).map { .text(String(cString: $0)) } ?? .null
                    }
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else if rc == SQLITE_CONSTRAINT {
                throw StoreError.constraintViolation(errmsg())
            } else {
                throw StoreError.stepFailed(errmsg())
            }
        }
        return rows
    }

    private func errmsg() -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// Run `block` inside BEGIN IMMEDIATE / COMMIT, ROLLBACK on throw.
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// Applies versioned SQL migrations transactionally.
public struct Migrator {
    public struct Migration {
        public let version: Int
        public let sql: String
        public init(version: Int, sql: String) {
            self.version = version
            self.sql = sql
        }
    }

    public let migrations: [Migration]

    public init(migrations: [Migration]) {
        self.migrations = migrations.sorted { $0.version < $1.version }
    }

    public func migrate(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations(
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
            """)
        let applied = Set(try db.query("SELECT version FROM schema_migrations")
            .compactMap { $0["version"]?.int })
        for migration in migrations where !applied.contains(Int64(migration.version)) {
            try db.transaction {
                for statement in migration.sql.components(separatedBy: ";") {
                    let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { try db.execute(trimmed) }
                }
                try db.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?)",
                    [.integer(Int64(migration.version)), .text(WorkshopTime.string(Date()))]
                )
            }
        }
    }
}
