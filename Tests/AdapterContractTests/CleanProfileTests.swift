import XCTest
@testable import WorkshopAdapters
@testable import WorkshopService
@testable import WorkshopCore

final class CleanProfileTests: XCTestCase {
    func testProfileSymlinkDriftDoesNotOverwriteTarget() throws {
        let home = NSTemporaryDirectory() + "clean-symlink-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/profiles/clean-v2/kimi", withIntermediateDirectories: true)
        let target = home + "/personal.toml"
        try "PERSONAL_CANARY".write(toFile: target, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: home + "/profiles/clean-v2/kimi/config.toml", withDestinationPath: target)
        XCTAssertThrowsError(try ProfileBuilder.kimiProfile(home: home))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "PERSONAL_CANARY")
    }

    func testEnvironmentExcludesPersonalHooks() {
        let env = ProfileBuilder.cleanEnvironment([
            "HOME": "/example", "PATH": "/personal/bin", "LANG": "en_US.UTF-8",
            "BASH_ENV": "/personal/instructions", "ZDOTDIR": "/personal",
            "NODE_OPTIONS": "--require personal", "PYTHONPATH": "/personal",
            "KIMI_CODE_EXPERIMENTAL_SECONDARY_MODEL": "1", "CODEX_HOME": "/personal",
            "WORKSHOP_MCP_PATH": "/untrusted"], profile: "/clean")
        XCTAssertEqual(env["HOME"], "/example")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/clean/config")
        for key in ["BASH_ENV", "ZDOTDIR", "NODE_OPTIONS", "PYTHONPATH", "CODEX_HOME",
                    "KIMI_CODE_EXPERIMENTAL_SECONDARY_MODEL", "WORKSHOP_MCP_PATH"] {
            XCTAssertNil(env[key], key)
        }
        XCTAssertFalse(env["PATH"]!.contains("personal"))
    }

    func testKimiProfileDriftIsRejectedWithoutDeletion() throws {
        let home = NSTemporaryDirectory() + "clean-profile-" + UUID().uuidString
        let profile = try ProfileBuilder.kimiProfile(home: home)
        let marker = profile + "/skills/PERSONAL_CANARY"
        try "private fixture".write(toFile: marker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ProfileBuilder.kimiProfile(home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
    }

    /// The pre-repair profile symlinked credentials into the user's real
    /// ~/.kimi-code store, letting a sandboxed refresh wipe it. The profile
    /// must hold a real directory instead — the symlink is migrated away.
    func testKimiCredentialsSymlinkMigratesToOwnedDirectory() throws {
        let home = NSTemporaryDirectory() + "clean-creds-" + UUID().uuidString
        let profile = try ProfileBuilder.kimiProfile(home: home)
        let credDir = profile + "/credentials"
        try FileManager.default.removeItem(atPath: credDir)
        try FileManager.default.createSymbolicLink(atPath: credDir, withDestinationPath: "/tmp")
        _ = try ProfileBuilder.kimiProfile(home: home)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: credDir))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: credDir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testSandboxBlocksInstructionCanariesButAllowsSourceAndNativeSkill() throws {
        let home = NSTemporaryDirectory() + "clean-sandbox-" + UUID().uuidString
        let workspace = home + "/worktrees/task"
        let fm = FileManager.default
        try fm.createDirectory(atPath: workspace + "/.agents/skills/custom", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: workspace + "/skills/custom", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/native-provider/skills", withIntermediateDirectories: true)
        let sandbox = home + "/isolation.sb"
        try ProfileBuilder.devinSandboxProfile(workshopHome: home, worktree: workspace, destination: sandbox)
        let blocked = [workspace + "/AGENTS.md", workspace + "/.agents/skills/custom/SKILL.md",
                       workspace + "/skills/custom/SKILL.md", home + "/AGENTS.md"]
        let allowed = [workspace + "/main.swift", home + "/native-provider/skills/SKILL.md"]
        for path in blocked + allowed {
            try "CANARY".write(toFile: path, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", sandbox, "/bin/cat", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            if blocked.contains(path) { XCTAssertNotEqual(process.terminationStatus, 0, path) }
            else { XCTAssertEqual(process.terminationStatus, 0, path) }
        }
    }

    func testDevinDisablesInstructionImportsPreservesModelAndNativeSidekick() throws {
        let home = NSTemporaryDirectory() + "clean-devin-" + UUID().uuidString
        let profile = try ProfileBuilder.devinProfile(home: home, model: "existing-profile")
        let data = try Data(contentsOf: URL(fileURLWithPath: profile + "/config/devin/config.json"))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(json["agent"]?["model"]?.stringValue, "existing-profile")
        XCTAssertEqual(json["read_config_from"]?["agents_standard"], .bool(false))
        XCTAssertEqual(json["subagents_enabled"], .bool(true))
    }
}
