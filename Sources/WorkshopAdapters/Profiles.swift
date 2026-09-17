import Foundation
import Darwin
import WorkshopCore
import WorkshopService

/// Builds isolated per-engineer profiles and HarnessLaunchSpecs from settled
/// live-probe facts. No credentials are copied except the documented
/// reference patterns (Devin static-key file symlink, Kimi credential-dir link).
public enum ProfileBuilder {
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty else { return path }
        return canonicalPath(parent) + "/" + (path as NSString).lastPathComponent
    }
    /// Reject pre-existing symlink drift before writing owned configuration.
    /// Credential links are intentionally separate and never passed here.
    static func validateOwnedPath(_ path: String, home: String) throws {
        let base = URL(fileURLWithPath: home).standardized.path
        var current = URL(fileURLWithPath: path).standardized.path
        guard current.hasPrefix(base + "/") else {
            throw WorkshopError.invalidRequest("Profile path is outside Workshop home")
        }
        while current != base {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current)) != nil {
                throw WorkshopError.invalidRequest("Workshop profile contains a symlink; review required")
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    public struct Paths: Sendable {
        public var home: String          // <WORKSHOP_HOME>
        public var devinBinary: String
        public var kimiBinary: String
        public var mcpBridge: String     // workshop-mcp executable path
        /// Runtime dir holding service.sock; forwarded to the bridge env.
        public var runtimeDir: String?
        public init(home: String, devinBinary: String, kimiBinary: String,
                    mcpBridge: String, runtimeDir: String? = nil) {
            self.home = home; self.devinBinary = devinBinary
            self.kimiBinary = kimiBinary; self.mcpBridge = mcpBridge
            self.runtimeDir = runtimeDir
        }
    }

    /// Environment stripped of provider credentials plus XDG isolation.
    public static func strippedEnv(profile: String) -> [String: String] {
        let env = cleanEnvironment(ProcessInfo.processInfo.environment, profile: profile)
        return env
    }

    /// Deliberately excludes shell startup hooks, injected runtimes, extra MCP
    /// configuration and personal agent selectors. HOME stays canonical for
    /// native authentication; filesystem policy isolates instruction discovery.
    public static func cleanEnvironment(_ source: [String: String], profile: String) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "TERM"] {
            if let value = source[key] { env[key] = value }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["XDG_CONFIG_HOME"] = profile + "/config"
        env["XDG_DATA_HOME"] = profile + "/data"
        env["XDG_CACHE_HOME"] = profile + "/cache"
        env["XDG_STATE_HOME"] = profile + "/state"
        return env
    }

    /// Devin profile: config/devin/config.json + data/devin/credentials.toml
    /// symlink to the canonical static key file (probe-verified pattern).
    public static func devinProfile(home: String, model: String) throws -> String {
        let profile = home + "/profiles/clean-v2/devin"
        for sub in ["config/devin/config.json", "data/devin", "cache", "state", "isolation.sb"] {
            try validateOwnedPath(profile + "/" + sub, home: home)
        }
        for sub in ["config/devin", "data/devin", "cache", "state"] {
            try FileManager.default.createDirectory(
                atPath: profile + "/" + sub, withIntermediateDirectories: true)
        }
        let config: [String: JSONValue] = [
            "agent": .object(["model": .string(model)]),
            "version": .number(1),
            "shell": .object(["setup_complete": .bool(true)]),
            "theme_mode": .string("dark"),
            "auto_update": .bool(false),
            "subagents_enabled": .bool(true),
            "read_config_from": .object([
                "agents_standard": .bool(false), "cursor": .bool(false),
                "windsurf": .bool(false), "claude": .bool(false),
                "copilot": .bool(false), "opencode": .bool(false),
                "zed": .bool(false)]),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(config))
        try data.write(to: URL(fileURLWithPath: profile + "/config/devin/config.json"))
        let link = profile + "/data/devin/credentials.toml"
        let target = NSHomeDirectory() + "/.local/share/devin/credentials.toml"
        if !FileManager.default.fileExists(atPath: link),
           FileManager.default.fileExists(atPath: target) {
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
        return profile
    }

    /// Devin sandbox profile (probe-verified). Session store is hardcoded at
    /// ~/.local/share/devin/cli, hence the allow carve-out.
    public static func devinSandboxProfile(workshopHome: String, worktree: String,
                                           destination: String) throws {
        let home = canonicalPath(NSHomeDirectory())
        let workshopHome = canonicalPath(workshopHome)
        let worktree = canonicalPath(worktree)
        // Reject syntax-bearing paths rather than interpolating sandbox source.
        for path in [home, workshopHome, worktree, destination] {
            guard !path.contains("\""), !path.contains("\\"), !path.contains("\n") else {
                throw WorkshopError.invalidRequest("Unsupported sandbox path")
            }
        }
        let text = """
        (version 1)
        (allow default)
        (deny file-read* (subpath "\(home)/.agents") (subpath "\(home)/.codex") (subpath "\(home)/.claude") (subpath "\(home)/.codeium") (subpath "\(home)/.cursor") (subpath "\(home)/.config") (subpath "\(home)/.devin") (subpath "\(home)/.cognition") (literal "\(home)/AGENTS.md") (literal "\(home)/CLAUDE.md"))
        (deny file-read* (regex #"(^|/)(AGENTS[.]md|CLAUDE[.]md|GEMINI[.]md|KIMI[.]md|[.]cursorrules|[.]windsurfrules)$"))
        (deny file-read* (regex #"/([.]agents|[.]claude|[.]cursor|[.]windsurf|[.]opencode|[.]kimi)/"))
        (deny file-read* (regex #"/[.]devin/(skills|rules|agents)(/|$)"))
        (deny file-read* (subpath "\(home)/.kimi-code/skills") (literal "\(home)/.kimi-code/config.toml") (subpath "\(home)/.local/share/devin/skills") (subpath "\(workshopHome)/profiles/clean-v2/kimi/skills"))
        (deny file-read* (subpath "\(worktree)/skills") (subpath "\(worktree)/.skills"))
        (deny file-write* (subpath "\(home)"))
        (allow file-write* (subpath "\(home)/.local/share/devin/cli") (subpath "\(workshopHome)") (subpath "\(worktree)"))
        """
        try text.write(toFile: destination, atomically: true, encoding: .utf8)
    }

    /// Per-generation write confinement. No grant covers Workshop control state,
    /// accepted snapshots, other writers or the registered source repository.
    public static func writerSandboxProfile(workshopHome: String, worktree: String,
                                             profile: String, token: String,
                                             destination: String) throws {
        let root = canonicalPath(workshopHome)
        let workspace = canonicalPath(worktree)
        guard workspace.hasPrefix(root + "/writer-runs/"), workspace.hasSuffix("/workspace") else {
            throw WorkshopError.invalidRequest("Writer workspace is outside the generation root")
        }
        for path in [profile, token] {
            guard !path.contains("\""), !path.contains("\\"), !path.contains("\n") else {
                throw WorkshopError.invalidRequest("Unsupported sandbox path")
            }
        }
        try devinSandboxProfile(workshopHome: root, worktree: workspace, destination: destination)
        var text = try String(contentsOfFile: destination)
        text = text.components(separatedBy: "\n").filter {
            !$0.hasPrefix("(deny file-write*") && !$0.hasPrefix("(allow file-write*")
        }.joined(separator: "\n")
        let userHome = canonicalPath(NSHomeDirectory())
        let run = (workspace as NSString).deletingLastPathComponent
        text += """

        (deny file-read* (regex #"/user[.]token$"))
        (deny file-write*)
        (allow file-write* (subpath "\(run)") (subpath "\(profile)/cache") (subpath "\(profile)/state") (subpath "\(profile)/data/devin/cli") (subpath "\(profile)/config/devin/cli") (subpath "\(userHome)/.local/share/devin/cli") (literal "/dev/null") (literal "\(userHome)/.local/share/fusion-codex-relay/.launch.lock"))
        (deny file-read* (subpath "\(root)"))
        (allow file-read* (subpath "\(run)") (subpath "\(profile)") (literal "\(token)"))
        (allow file-read-metadata (literal "\(root)") (literal "\(root)/profiles") (literal "\(root)/profiles/clean-v2"))
        """
        try text.write(toFile: destination, atomically: true, encoding: .utf8)
    }

    /// Kimi profile: minimal owned config, empty skills directory, and a
    /// credentials DIRECTORY reference. Never copies the personal configuration.
    public static func kimiProfile(home: String) throws -> String {
        let profile = home + "/profiles/clean-v2/kimi"
        for sub in ["skills", "workspace", "config.toml", "device_id", "isolation.sb"] {
            try validateOwnedPath(profile + "/" + sub, home: home)
        }
        for sub in ["skills", "workspace"] {
            try FileManager.default.createDirectory(
                atPath: profile + "/" + sub, withIntermediateDirectories: true)
        }
        guard try FileManager.default.contentsOfDirectory(atPath: profile + "/skills").isEmpty else {
            throw WorkshopError.invalidRequest("Workshop Kimi skill profile has drifted; review required")
        }
        let link = profile + "/credentials"
        let target = NSHomeDirectory() + "/.kimi-code/credentials"
        if !FileManager.default.fileExists(atPath: link),
           FileManager.default.fileExists(atPath: target) {
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
        // config.toml: minimal managed-kimi-code profile. The api_key field is
        // an empty placeholder in the canonical config (verified: both files
        // carry `""`); real auth is OAuth via the linked credentials dir.
        // Never copy the user's full config — it holds unrelated provider keys.
        let dest = profile + "/config.toml"
        do {
            let config = """
            default_model = "kimi-code/k3"

            [providers."managed:kimi-code"]
            type = "kimi"
            api_key = ""
            base_url = "https://api.kimi.com/coding/v1"

            [providers."managed:kimi-code".oauth]
            storage = "file"
            key = "oauth/kimi-code"

            [models."kimi-code/k3"]
            provider = "managed:kimi-code"
            model = "k3"
            max_context_size = 1048576
            capabilities = [ "thinking", "always_thinking", "image_in", "video_in", "tool_use" ]
            display_name = "K3"
            support_efforts = [ "low", "high", "max" ]
            default_effort = "high"
            """
            try config.write(toFile: dest, atomically: true, encoding: .utf8)
        }
        let did = NSHomeDirectory() + "/.kimi-code/device_id"
        if FileManager.default.fileExists(atPath: did),
           !FileManager.default.fileExists(atPath: profile + "/device_id") {
            try? FileManager.default.copyItem(atPath: did, toPath: profile + "/device_id")
        }
        return profile
    }

    /// Devin launch spec: sandboxed `devin acp`, project-config MCP injection.
    public static func devinSpec(paths: Paths, worktree: String, model: String) throws
        -> (HarnessLaunchSpec, sandboxPath: String) {
        let profile = try devinProfile(home: paths.home, model: model)
        let sb = profile + "/isolation.sb"
        try devinSandboxProfile(workshopHome: paths.home, worktree: worktree,
                                destination: sb)
        var env = strippedEnv(profile: profile)
        env["WORKSHOP_MCP_PATH"] = paths.mcpBridge
        env["WORKSHOP_TOKEN_DEVIN"] = paths.home + "/profiles/devin/token"
        if let rt = paths.runtimeDir { env["WORKSHOP_RUNTIME_DIR"] = rt }
        var spec = HarnessLaunchSpec(
            engineer: .devin,
            executable: "/usr/bin/sandbox-exec",
            args: ["-f", sb, paths.devinBinary,
                   "--config", profile + "/config/devin/config.json",
                   "--permission-mode", "accept-edits", "acp"],
            env: env, cwd: worktree, sandboxProfilePath: sb,
            mcpInjection: .devinProjectConfigFile,
            qualifiedVersion: "3000.10.21", modelSelection: model)
        spec.versionProbePath = paths.devinBinary
        spec.worktreeRoot = paths.home + "/worktrees"
        return (spec, sb)
    }

    /// Kimi launch spec: `kimi acp` with KIMI_CODE_HOME profile, ACP mcpServers.
    /// Concurrency: at most ONE Kimi process — serialized by the service's
    /// single-turn-per-(task,engineer) guard plus a per-engineer limit of 1.
    public static func kimiSpec(paths: Paths, worktree: String) throws -> HarnessLaunchSpec {
        let profile = try kimiProfile(home: paths.home)
        var env = strippedEnv(profile: profile)
        env["KIMI_CODE_HOME"] = profile
        env["WORKSHOP_MCP_PATH"] = paths.mcpBridge
        env["WORKSHOP_TOKEN_KIMI"] = paths.home + "/profiles/kimi/token"
        if let rt = paths.runtimeDir { env["WORKSHOP_RUNTIME_DIR"] = rt }
        let sb = profile + "/isolation.sb"
        try devinSandboxProfile(workshopHome: paths.home, worktree: worktree, destination: sb)
        var spec = HarnessLaunchSpec(
            engineer: .kimi, executable: "/usr/bin/sandbox-exec", args: ["-f", sb, paths.kimiBinary, "acp"],
            env: env, cwd: worktree,
            mcpInjection: .acpSessionParam,
            qualifiedVersion: "0.42.0", modelSelection: "kimi-code/k3")
        spec.worktreeRoot = paths.home + "/worktrees"
        spec.versionProbePath = paths.kimiBinary
        spec.sandboxProfilePath = sb
        return spec
    }
}
