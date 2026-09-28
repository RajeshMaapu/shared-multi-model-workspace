import XCTest
@testable import WorkshopCore
@testable import WorkshopService
@testable import WorkshopStore

final class TaskWorkspaceTests: XCTestCase {
    private var root: String!
    private var home: String { root + "/home" }
    private var repository: String { root + "/repo" }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("workspace-" + UUID().uuidString).path
        for path in [repository, home + "/config"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        _ = try git(repository, ["init"])
        _ = try git(repository, ["-c", "user.name=Workshop Test", "-c", "user.email=workshop@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
        let config: JSONValue = .object(["projects": .array([.object([
            "id": .string("project"), "path": .string(repository)])])])
        try JSONEncoder().encode(config).write(to: URL(fileURLWithPath: home + "/config/projects.json"))
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(atPath: root) }
    }

    private func git(_ cwd: String, _ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRegisteredWorktreeAndDirtyReuse() throws {
        let first = try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_one"), workspaceRef: "project")
        XCTAssertEqual(first.repositoryPath, repository)
        XCTAssertEqual(try git(first.path, ["symbolic-ref", "--short", "HEAD"]), "workshop/task_one")
        try "dirty".write(toFile: first.path + "/dirty.txt", atomically: true, encoding: .utf8)
        let reused = try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_one"), workspaceRef: "project")
        XCTAssertEqual(first.path, reused.path)
        XCTAssertEqual(try String(contentsOfFile: reused.path + "/dirty.txt"), "dirty")
        let second = try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_two"), workspaceRef: "project")
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.baseRevision, second.baseRevision)
    }

    func testRegisteredProjectAcceptsAnotherGitWorktreeReference() throws {
        let checkout = root + "/codex-checkout"
        _ = try git(repository, ["worktree", "add", "--detach", checkout, "HEAD"])
        let prepared = try WorkspaceManager.prepareTaskWorkspace(
            homeDir: home, taskID: TaskID("task_codex"), workspaceRef: checkout)
        XCTAssertEqual(prepared.repositoryPath, repository)
        XCTAssertEqual(try git(prepared.path, ["symbolic-ref", "--short", "HEAD"]),
                       "workshop/task_codex")
        XCTAssertNotEqual(prepared.path, checkout)
    }

    func testUnregisteredRepositoryStillRejected() throws {
        let unrelated = root + "/unrelated"
        try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
        _ = try git(unrelated, ["init"])
        XCTAssertThrowsError(try WorkspaceManager.prepareTaskWorkspace(
            homeDir: home, taskID: TaskID("task_unrelated"), workspaceRef: unrelated))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/worktrees/task_unrelated"))
    }

    func testInvalidReferenceAndExistingScratchFailClosed() throws {
        XCTAssertThrowsError(try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_unknown"), workspaceRef: "missing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/worktrees/task_unknown"))
        let scratch = try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_scratch"), workspaceRef: nil)
        try "preserve".write(toFile: scratch.path + "/dirty.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_scratch"), workspaceRef: "project"))
        XCTAssertEqual(try String(contentsOfFile: scratch.path + "/dirty.txt"), "preserve")
    }

    func testSymlinkAndTraversalRejected() throws {
        let outside = root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/worktrees", withDestinationPath: outside)
        XCTAssertThrowsError(try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_symlink"), workspaceRef: nil))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
        XCTAssertThrowsError(try WorkspaceManager.worktreePath(homeDir: home, taskID: TaskID("task_../../outside")))
    }

    func testBranchConflictDoesNotCreateScratch() throws {
        _ = try git(repository, ["branch", "workshop/task_conflict"])
        XCTAssertThrowsError(try WorkspaceManager.prepareTaskWorkspace(homeDir: home, taskID: TaskID("task_conflict"), workspaceRef: "project"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/worktrees/task_conflict"))
    }

    func testServiceKeepsCanonicalWorkspaceAndIsolatesParticipantCopies() async throws {
        let adapters = EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
        let service = try CollaborationService(databasePath: home + "/db.sqlite", adapters: adapters,
                                               homeDir: home, wakeupCoalescence: .zero)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "workspace", title: "Workspace", objective: "Test workspace",
            phase: .execution, participants: [.kimi], workspaceRef: "project", collaborationMode: .requestedPeers))
        await service.start()
        await service.awaitIdle()
        let detail = try await service.getTask(receipt.taskID)
        let workspace = try XCTUnwrap(detail.workspace)
        XCTAssertEqual(workspace.repositoryPath, repository)
        let first = try XCTUnwrap(adapters[0].receivedContexts.first?.workspace?.path)
        let second = try XCTUnwrap(adapters[1].receivedContexts.first?.workspace?.path)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, workspace.path)
        XCTAssertNotEqual(second, workspace.path)
        XCTAssertTrue(first.hasPrefix(home + "/writer-runs/"))
        XCTAssertTrue(second.hasPrefix(home + "/writer-runs/"))
        let repo = WorkshopRepository(db: try Database(path: home + "/db.sqlite"))
        XCTAssertEqual(try repo.taskWorkspace(receipt.taskID), workspace)
        await service.shutdown()
        let reopened = try CollaborationService(databasePath: home + "/db.sqlite", adapters: [], dispatcherEnabled: false, homeDir: home)
        let reloaded = try await reopened.getTask(receipt.taskID)
        XCTAssertEqual(reloaded.workspace, workspace)
        await reopened.shutdown()
    }

    func testInvalidRegistryBlocksBeforeAdapterTurn() async throws {
        let adapter = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        let service = try CollaborationService(databasePath: home + "/db.sqlite", adapters: [adapter], homeDir: home)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "bad-workspace", title: "Workspace", objective: "Test workspace",
            phase: .execution, participants: [], workspaceRef: "missing"))
        await service.start()
        await service.awaitIdle()
        XCTAssertEqual(adapter.turnCount, 0)
        let detail = try await service.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .blocked)
        XCTAssertNil(detail.workspace)
        await service.shutdown()
    }

    func testChangeRequestKeepsWriterAuthorityWhenCoalescedWithMention() async throws {
        let adapter = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        let databasePath = home + "/coalesced-writer.sqlite"
        let service = try CollaborationService(databasePath: databasePath,
            adapters: [adapter], dispatcherEnabled: false,
            homeDir: home, wakeupCoalescence: .zero)
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "coalesced-writer", title: "Revise",
            objective: "Revise reviewed files", phase: .execution,
            participants: [], workspaceRef: "project", collaborationMode: .ownerOnly))
        let repo = WorkshopRepository(db: try Database(path: databasePath))
        let now = Date()
        try repo.insertSubtask(Subtask(id: SubtaskID("sub_coalesced_writer"),
            taskID: receipt.taskID, title: "Revise", ownerID: .devin,
            generation: 1, state: .working, verification: "changes_requested",
            createdAt: now, updatedAt: now))
        try repo.updateTaskState(receipt.taskID, .working, at: now)
        try repo.insertWakeup(taskID: receipt.taskID, engineerID: .devin,
                              reason: "changes_requested", triggerSeq: nil, at: now)
        try repo.insertWakeup(taskID: receipt.taskID, engineerID: .devin,
                              reason: "mention", triggerSeq: nil, at: now)
        await service.start()
        for _ in 0..<100 where adapter.receivedContexts.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(adapter.receivedContexts.first?.workspace?.state, "writer")
        await service.shutdown()
    }

    func testBlockedWorkspaceCanRetryAfterRegistryRepair() async throws {
        let adapter = FakeAdapter(engineer: .devin, delayPerDelta: .zero)
        let service = try CollaborationService(databasePath: home + "/retry.sqlite",
            adapters: [adapter], homeDir: home, wakeupCoalescence: .zero)
        adapter.toolRunner = { [weak service] name, args, principal in
            guard let service else { return .null }
            return try await service.callTool(name, args: args, principal: principal)
        }
        adapter.script = { context in
            guard let sub = context.subtask else { return [.text("ok")] }
            return [.toolCall("workshop_report_result", .object([
                "task_id": .string(context.task.id.rawValue),
                "subtask_id": .string(sub.id.rawValue),
                "summary": .string("done"),
                "generation": .number(Double(sub.generation))]))]
        }
        let receipt = try await service.createTask(CreateTaskRequest(
            schemaVersion: 2, idempotencyKey: "retry-workspace", title: "Workspace",
            objective: "Test workspace", phase: .execution, participants: [],
            workspaceRef: "late-project"))
        await service.start()
        await service.awaitIdle()
        let blocked = try await service.getTask(receipt.taskID)
        XCTAssertEqual(blocked.task.state, .blocked)
        XCTAssertEqual(adapter.turnCount, 0)
        let store = WorkshopRepository(db: try Database(path: home + "/retry.sqlite"))
        let subtask = try XCTUnwrap(blocked.subtasks.first)
        try store.updateSubtaskState(subtask.id, .blocked, at: Date())

        let config: JSONValue = .object(["projects": .array([.object([
            "id": .string("late-project"), "path": .string(repository)])])])
        try JSONEncoder().encode(config).write(to:
            URL(fileURLWithPath: home + "/config/projects.json"))
        try await service.resumeTask(taskID: receipt.taskID, principal: .user)
        var resumed = try await service.getTask(receipt.taskID)
        for _ in 0..<100 where resumed.task.state != .verifying {
            try await Task.sleep(for: .milliseconds(20))
            resumed = try await service.getTask(receipt.taskID)
        }
        await service.awaitIdle()
        resumed = try await service.getTask(receipt.taskID)
        XCTAssertEqual(resumed.task.state, .verifying)
        XCTAssertEqual(resumed.subtasks.first?.state, .review)
        XCTAssertGreaterThan(adapter.turnCount, 0)
        await service.shutdown()
    }
}
