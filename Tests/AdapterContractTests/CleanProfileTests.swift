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

    func testKimiHomeIsTheCleanProfile() {
        let profile = "/tmp/workshop-clean-kimi"
        let env = ProfileBuilder.kimiEnvironment(profile: profile, source: [
            "HOME": "/test-home", "PATH": "/test-home/bin",
            "BASH_ENV": "/test-home/hook", "USER": "test",
        ])
        XCTAssertEqual(env["HOME"], profile)
        XCTAssertEqual(env["KIMI_CODE_HOME"], profile)
        XCTAssertNil(env["BASH_ENV"])
        XCTAssertFalse(env["PATH"]!.contains("test-home"))
    }

    func testKimiProfileDriftIsRejectedWithoutDeletion() throws {
        let home = NSTemporaryDirectory() + "clean-profile-" + UUID().uuidString
        let profile = try ProfileBuilder.kimiProfile(home: home)
        let marker = profile + "/skills/PERSONAL_CANARY"
        try "private fixture".write(toFile: marker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ProfileBuilder.kimiProfile(home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
    }

    func testLegacyKimiCredentialDirectoryIsBackedUpAndLinked() throws {
        let home = NSTemporaryDirectory() + "clean-kimi-credentials-" + UUID().uuidString
        let fm = FileManager.default
        let profile = home + "/profiles/clean-v2/kimi"
        let canonical = home + "/canonical/credentials"
        try fm.createDirectory(atPath: profile + "/credentials", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: canonical, withIntermediateDirectories: true)
        try "OLD".write(toFile: profile + "/credentials/old.json", atomically: true, encoding: .utf8)
        try "NEW".write(toFile: canonical + "/current.json", atomically: true, encoding: .utf8)

        try ProfileBuilder.reconcileKimiCredentialLink(home: home, profile: profile, target: canonical)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: profile + "/credentials"), canonical)
        XCTAssertEqual(try String(contentsOfFile: profile + "/credentials/current.json", encoding: .utf8), "NEW")
        let backups = try fm.contentsOfDirectory(atPath: home + "/backups")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOfFile: home + "/backups/" + backups[0] + "/old.json", encoding: .utf8), "OLD")

        try ProfileBuilder.reconcileKimiCredentialLink(home: home, profile: profile, target: canonical)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home + "/backups").count, 1)
    }

    func testKimiCredentialLinkDriftIsRejected() throws {
        let home = NSTemporaryDirectory() + "clean-kimi-drift-" + UUID().uuidString
        let fm = FileManager.default
        let profile = home + "/profiles/clean-v2/kimi"
        let canonical = home + "/canonical/credentials"
        try fm.createDirectory(atPath: profile, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: canonical, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: profile + "/credentials", withDestinationPath: home + "/wrong")
        XCTAssertThrowsError(try ProfileBuilder.reconcileKimiCredentialLink(
            home: home, profile: profile, target: canonical))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: profile + "/credentials"), home + "/wrong")
    }

    func testKimiOAuthReferenceUsesCurrentRegionAndCredentialKey() throws {
        let root = NSTemporaryDirectory() + "clean-kimi-oauth-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let path = root + "/config.toml"
        try """
        [providers."managed:kimi-code"]
        type = "kimi"
        api_key = ""
        base_url = "https://api.kimi.ai/coding/v1"
        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/kimi-code-env-0123abcd"
        oauth_host = "https://auth.kimi.ai"
        [providers.deepseek]
        type = "openai"
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let ref = try ProfileBuilder.kimiOAuthReference(path: path)
        XCTAssertEqual(ref.baseURL, "https://api.kimi.ai/coding/v1")
        XCTAssertEqual(ref.key, "oauth/kimi-code-env-0123abcd")
        XCTAssertEqual(ref.oauthHost, "https://auth.kimi.ai")

        try """
        [providers."managed:kimi-code"]
        base_url = "https://untrusted.example/coding/v1"
        [providers."managed:kimi-code".oauth]
        key = "oauth/kimi-code-env-0123abcd"
        oauth_host = "https://auth.kimi.ai"
        """.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ProfileBuilder.kimiOAuthReference(path: path))
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
