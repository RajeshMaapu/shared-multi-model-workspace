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
        let dir = homeDir + "/worktrees/" + taskID.rawValue
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Prepare the task workspace. If `workspaceRef` names a registered git repo,
    /// create a detached worktree on a workshop/<task_id> branch; otherwise a plain dir.
    /// Returns (path, baseCommit). Never deletes existing worktrees.
    public static func prepareWorkspace(homeDir: String, taskID: TaskID,
                                        workspaceRef: String?) throws -> (path: String, baseRevision: String?) {
        let dest = homeDir + "/worktrees/" + taskID.rawValue
        let fm = FileManager.default
        if fm.fileExists(atPath: dest) {
            return (dest, gitOutput(at: dest, args: ["rev-parse", "HEAD"]))
        }
        guard let workspaceRef,
              let project = registeredProjects(homeDir: homeDir)
                .first(where: { $0.id == workspaceRef || $0.path == workspaceRef }),
              isGitRepo(project.path) else {
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            return (dest, nil)
        }
        let base = gitOutput(at: project.path, args: ["rev-parse", "HEAD"])
        let status = runGit(at: project.path, args: [
            "worktree", "add", dest, "-b", "workshop/" + taskID.rawValue, "HEAD",
        ])
        guard status == 0 else {
            log.error("git worktree add failed for \(project.path, privacy: .public)")
            try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
            return (dest, nil)
        }
        return (dest, base)
    }

    /// Resolve `path` inside `workspace`, rejecting traversal and symlink escapes (T26).
    public static func resolveInsideWorkspace(_ workspace: String, _ path: String) throws -> String {
        let rootReal = ((workspace as NSString).standardizingPath as NSString)
            .resolvingSymlinksInPath
        // Reject ".." components outright — they can never escape legitimately.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") || path.hasPrefix("/") {
            throw WorkshopError.workspaceEscape(path)
        }
        let real = ((rootReal + "/" + path) as NSString).resolvingSymlinksInPath
        guard real == rootReal || real.hasPrefix(rootReal + "/") else {
            throw WorkshopError.workspaceEscape(path)
        }
        return real
    }

    private static func isGitRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
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
