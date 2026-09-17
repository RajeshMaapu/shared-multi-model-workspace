import Foundation
import os
import WorkshopCore

/// Workspace manager: task worktrees and project registry (spec §9.1).
public enum WorkspaceManager {
    private static let log = Logger(subsystem: "ai.maapu.workshop", category: "workspace")

    /// Registered projects: <home>/config/projects.json {"projects":[{"id","path"}]}.
    public struct RegisteredProject: Codable, Equatable, Sendable {
        public var id: String
        public var path: String
    }

    public static func registeredProjects(homeDir: String) -> [RegisteredProject] {
        let path = homeDir + "/config/projects.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let list = json["projects"]?.arrayValue else { return [] }
        return list.compactMap { item in
            guard let id = item["id"]?.stringValue,
                  let path = item["path"]?.stringValue else { return nil }
            return RegisteredProject(id: id, path: path)
        }
    }

    /// Default per-task worktree/working directory (created on demand by callers).
    public static func worktreePath(homeDir: String, taskID: TaskID) throws -> String {
        try safeDestination(homeDir: homeDir, taskID: taskID)
        let dir = canonical(homeDir) + "/worktrees/" + taskID.rawValue
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Prepare the task workspace. If `workspaceRef` names a registered git repo,
    /// create a detached worktree on a workshop/<task_id> branch; otherwise a plain dir.
    /// Returns (path, baseCommit). Never deletes existing worktrees.
    public static func prepareWorkspace(homeDir: String, taskID: TaskID,
                                        workspaceRef: String?) throws -> (path: String, baseRevision: String?) {
        let workspace = try prepareTaskWorkspace(homeDir: homeDir, taskID: taskID,
                                                  workspaceRef: workspaceRef)
        return (workspace.path, workspace.baseRevision)
    }

    /// Resolve `path` inside `workspace`, rejecting traversal and symlink escapes (T26).
    public static func resolveInsideWorkspace(_ workspace: String, _ path: String) throws -> String {
        let rootReal = ((workspace as NSString).standardizingPath as NSString)
            .resolvingSymlinksInPath
        // Reject ".." components outright — they can never escape legitimately.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") {
            throw WorkshopError.workspaceEscape(path)
        }
        // Absolute paths are accepted and checked against the same root.
        let joined = path.hasPrefix("/") ? path : rootReal + "/" + path
        let real = (joined as NSString).resolvingSymlinksInPath
        guard real == rootReal || real.hasPrefix(rootReal + "/") else {
            throw WorkshopError.workspaceEscape(path)
        }
        return real
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func safeDestination(homeDir: String, taskID: TaskID) throws {
        guard taskID.rawValue.count <= 120,
              taskID.rawValue.range(of: "^task_[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw WorkshopError.invalidRequest("Invalid task workspace identifier")
        }
        let fm = FileManager.default
        for path in [homeDir, homeDir + "/worktrees", homeDir + "/worktrees/" + taskID.rawValue] {
            if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                throw WorkshopError.invalidRequest("Task workspace contains a symlink; preserved for review")
            }
            var directory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue {
                throw WorkshopError.invalidRequest("Task workspace is not a directory; preserved for review")
            }
        }
    }

    public static func prepareTaskWorkspace(homeDir: String, taskID: TaskID,
                                           workspaceRef: String?) throws -> TaskWorkspace {
        try safeDestination(homeDir: homeDir, taskID: taskID)
        let fm = FileManager.default
        let home = canonical(homeDir)
        let parent = home + "/worktrees"
        let dest = parent + "/" + taskID.rawValue
        guard let workspaceRef else {
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            return TaskWorkspace(taskID: taskID, path: dest)
        }
        guard !workspaceRef.isEmpty,
              let project = registeredProjects(homeDir: home).first(where: {
                  $0.id == workspaceRef || $0.path == workspaceRef
              }) else {
            throw WorkshopError.invalidRequest("Requested workspace is not a registered repository")
        }
        let repository = canonical(project.path)
        let top = try checkedGit(at: repository, args: ["rev-parse", "--show-toplevel"])
        guard canonical(top) == repository else {
            throw WorkshopError.invalidRequest("Registered project must name the repository root")
        }
        let base = try checkedGit(at: repository, args: ["rev-parse", "--verify", "HEAD"])
        let common = try checkedGit(at: repository, args: ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let branch = "workshop/" + taskID.rawValue
        if fm.fileExists(atPath: dest) {
            guard let existingTop = try? checkedGit(at: dest, args: ["rev-parse", "--show-toplevel"]),
                  let existingBranch = try? checkedGit(at: dest, args: ["symbolic-ref", "--short", "HEAD"]),
                  let existingCommon = try? checkedGit(at: dest, args: ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
                  canonical(existingTop) == dest, existingBranch == branch,
                  canonical(existingCommon) == canonical(common) else {
                throw WorkshopError.invalidRequest("Existing task workspace does not match requested repository; preserved for review")
            }
            let revision = try checkedGit(at: dest, args: ["rev-parse", "HEAD"])
            return TaskWorkspace(taskID: taskID, repositoryPath: repository, branch: branch,
                                 path: dest, baseRevision: revision)
        }
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        _ = try checkedGit(at: repository, args: ["worktree", "add", "-b", branch, dest, base])
        return TaskWorkspace(taskID: taskID, repositoryPath: repository, branch: branch,
                             path: dest, baseRevision: base)
    }

    private static func checkedGit(at cwd: String, args: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkshopError.invalidRequest("Repository operation failed; existing workspace preserved for review")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func runGit(at cwd: String, args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func gitOutput(at cwd: String, args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
