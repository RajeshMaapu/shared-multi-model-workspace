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

    /// Schema v2: artifacts, usage_samples, wakeups, checkpoints; participants.last_read_seq;
    /// messages.structured.
    public static let v2 = Migrator.Migration(version: 2, sql: """
        CREATE TABLE artifacts(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            content_hash TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            mime TEXT,
            producer TEXT NOT NULL,
            base_revision TEXT,
            validation TEXT NOT NULL DEFAULT 'unverified',
            description TEXT,
            created_at TEXT NOT NULL
        );

        CREATE TABLE usage_samples(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            engineer_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT,
            native_session_id TEXT,
            turn_id TEXT,
            input INTEGER,
            output INTEGER,
            cache_read INTEGER,
            cache_write INTEGER,
            source TEXT NOT NULL,
            observed_at TEXT NOT NULL
        );

        CREATE TABLE wakeups(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            engineer_id TEXT NOT NULL,
            reason TEXT NOT NULL,
            trigger_seq INTEGER,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE checkpoints(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            engineer_id TEXT NOT NULL,
            role TEXT NOT NULL,
            worker_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            schema_version INTEGER NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL
        );

        ALTER TABLE participants ADD COLUMN last_read_seq INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE messages ADD COLUMN structured TEXT
        """)

    /// Schema v3: proposals, reports, decisions; tasks.report_revision and
    /// tasks.cancel_requested_at; subtasks.risk and subtasks.verification.
    public static let v3 = Migrator.Migration(version: 3, sql: """
        CREATE TABLE proposals(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            author TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1,
            visibility TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE reports(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            revision INTEGER NOT NULL,
            author TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE(task_id, revision)
        );

        CREATE TABLE decisions(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            kind TEXT NOT NULL,
            revision INTEGER,
            scope TEXT,
            author TEXT NOT NULL,
            body TEXT NOT NULL,
            related_id TEXT,
            created_at TEXT NOT NULL
        );

        ALTER TABLE tasks ADD COLUMN report_revision INTEGER;
        ALTER TABLE tasks ADD COLUMN cancel_requested_at TEXT;
        ALTER TABLE subtasks ADD COLUMN risk TEXT NOT NULL DEFAULT 'normal';
        ALTER TABLE subtasks ADD COLUMN verification TEXT NOT NULL DEFAULT 'none'
        """)

    /// Schema v4: quota_snapshots, reservations, leases, outbox_cursors,
    /// turns; artifacts.generation; checkpoints.valid.
    public static let v4 = Migrator.Migration(version: 4, sql: """
        CREATE TABLE quota_snapshots(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bucket TEXT NOT NULL,
            remaining TEXT NOT NULL,
            unit TEXT,
            reset_at TEXT,
            source TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            availability TEXT NOT NULL
        );

        CREATE TABLE reservations(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            engineer_id TEXT NOT NULL,
            bucket TEXT NOT NULL,
            reserved INTEGER NOT NULL,
            committed INTEGER,
            state TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            created_at TEXT NOT NULL
        );

        CREATE TABLE leases(
            resource TEXT PRIMARY KEY,
            owner TEXT NOT NULL,
            task_id TEXT,
            generation INTEGER NOT NULL DEFAULT 1,
            expires_at TEXT NOT NULL,
            url TEXT,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE outbox_cursors(
            consumer TEXT PRIMARY KEY,
            last_seq INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE turns(
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            subtask_id TEXT,
            engineer_id TEXT NOT NULL,
            generation INTEGER,
            state TEXT NOT NULL,
            started_at TEXT NOT NULL,
            first_event_at TEXT,
            ended_at TEXT,
            native_session_id TEXT,
            request_ids TEXT
        );

        ALTER TABLE artifacts ADD COLUMN generation INTEGER;
        ALTER TABLE checkpoints ADD COLUMN valid INTEGER NOT NULL DEFAULT 1
        """)

    public static let v5 = Migrator.Migration(version: 5, sql: """
        CREATE TABLE task_ingress(
            task_id TEXT PRIMARY KEY REFERENCES tasks(id),
            principal TEXT NOT NULL,
            request_json TEXT NOT NULL,
            source_task_id TEXT,
            invocation_id TEXT,
            last_acknowledged_seq INTEGER NOT NULL DEFAULT 0,
            UNIQUE(principal, source_task_id, invocation_id)
        )
        """)

    public static let v6 = Migrator.Migration(version: 6, sql: """
        CREATE TABLE task_workspaces(
            task_id TEXT PRIMARY KEY REFERENCES tasks(id),
            repository_path TEXT,
            branch TEXT,
            path TEXT NOT NULL UNIQUE,
            base_revision TEXT,
            state TEXT NOT NULL
        )
        """)

    public static let v7 = Migrator.Migration(version: 7, sql: """
        CREATE TABLE writer_generations(
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
            engineer TEXT NOT NULL, path TEXT NOT NULL UNIQUE, base_path TEXT NOT NULL,
            state TEXT NOT NULL, snapshot_path TEXT UNIQUE, digest TEXT, token_hash TEXT UNIQUE
        );
        CREATE UNIQUE INDEX one_current_writer ON writer_generations(task_id)
            WHERE state IN ('writing','sealed');
        """)
    public static let all = Migrator(migrations: [v1, v2, v3, v4, v5, v6, v7])
}
