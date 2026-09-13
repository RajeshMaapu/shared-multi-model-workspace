import Foundation

public enum Migrations {
    /// Schema v1: tasks, participants, messages, subtasks, operations, outbox, session_bindings.
    public static let v1 = Migrator.Migration(version: 1, sql: """
        CREATE TABLE tasks(
            id TEXT PRIMARY KEY,
            channel TEXT NOT NULL,
            title TEXT NOT NULL,
            brief TEXT NOT NULL,
            phase TEXT NOT NULL,
            state TEXT NOT NULL,
            scope_revision INTEGER NOT NULL DEFAULT 1,
            approval_revision INTEGER,
            budget_policy_ref TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE participants(
            task_id TEXT NOT NULL REFERENCES tasks(id),
            engineer_id TEXT NOT NULL,
            membership TEXT NOT NULL,
            read_cursor INTEGER NOT NULL DEFAULT 0,
            subscriptions TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY(task_id, engineer_id)
        );

        CREATE TABLE messages(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            seq INTEGER NOT NULL,
            author_kind TEXT NOT NULL,
            author_id TEXT,
            kind TEXT NOT NULL,
            body TEXT NOT NULL,
            reply_to TEXT,
            correlation_id TEXT,
            revision INTEGER NOT NULL DEFAULT 1,
            delivery_state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(task_id, seq)
        );

        CREATE TABLE subtasks(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            title TEXT NOT NULL,
            acceptance TEXT NOT NULL DEFAULT '[]',
            dependencies TEXT NOT NULL DEFAULT '[]',
            owner_id TEXT,
            generation INTEGER NOT NULL DEFAULT 0,
            lease_expires_at TEXT,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE operations(
            idempotency_key TEXT PRIMARY KEY,
            principal TEXT NOT NULL,
            payload_hash TEXT NOT NULL,
            result_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE TABLE outbox(
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT REFERENCES tasks(id),
            event_type TEXT NOT NULL,
            recipients TEXT NOT NULL DEFAULT '[]',
            payload TEXT NOT NULL,
            delivery_state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            delivered_at TEXT
        );

        CREATE TABLE session_bindings(
            task_id TEXT NOT NULL,
            engineer_id TEXT NOT NULL,
            role TEXT NOT NULL,
            worker_id TEXT NOT NULL,
            native_session_id TEXT,
            profile_revision INTEGER NOT NULL DEFAULT 1,
            model_selection TEXT,
            recovery_state TEXT NOT NULL,
            PRIMARY KEY(task_id, engineer_id, role, worker_id)
        )
        """)

    public static let all = Migrator(migrations: [v1])
}
