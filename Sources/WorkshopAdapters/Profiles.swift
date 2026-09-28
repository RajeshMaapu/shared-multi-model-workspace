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
        /// Daemon Streamable HTTP MCP endpoint; forwarded to launch specs.
        public var mcpURL: String?
        public init(home: String, devinBinary: String, kimiBinary: String,
                    mcpBridge: String, runtimeDir: String? = nil,
                    mcpURL: String? = nil) {
            self.home = home; self.devinBinary = devinBinary
            self.kimiBinary = kimiBinary; self.mcpBridge = mcpBridge
            self.runtimeDir = runtimeDir
            self.mcpURL = mcpURL
        }
    }

    /// Environment stripped of provider credentials plus XDG isolation.
    public static func strippedEnv(profile: String) -> [String: String] {
        let env = cleanEnvironment(ProcessInfo.processInfo.environment, profile: profile)
        return env
    }

    /// Kimi watches agent roots under HOME during ACP session creation. Keep
    /// that discovery inside the empty Workshop profile; OAuth uses the
    /// explicit KIMI_CODE_HOME and linked credential directory instead.
    public static func kimiEnvironment(profile: String, source: [String: String]) -> [String: String] {
        var env = cleanEnvironment(source, profile: profile)
        env["HOME"] = profile
        env["KIMI_CODE_HOME"] = profile
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
            "permissions": .object(["allow": .array([
                .string("read"), .string("grep"), .string("glob"),
                .string("exec"), .string("edit"),
                .string("mcp__workshop__*")])]),
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
    /// The profile-scoped write grants differ per harness: Devin's session store
    /// is hardcoded under ~/.local/share/devin/cli plus a few config dirs, while
    /// Kimi writes session storage across its whole KIMI_CODE_HOME profile and
    /// fs.watch()es that directory — a Devin-shaped allowlist makes Kimi's
    /// session/new fail with "storage write failed: permission denied".
    public static func writerSandboxProfile(workshopHome: String, worktree: String,
                                             profile: String, token: String,
                                             destination: String,
                                             engineer: EngineerID = .devin,
                                             kimiCredentialPath: String? = nil,
                                             readOnlyPriorWorkspace: String? = nil) throws {
        let root = canonicalPath(workshopHome)
        let workspace = canonicalPath(worktree)
        guard workspace.hasPrefix(root + "/writer-runs/"), workspace.hasSuffix("/workspace") else {
            throw WorkshopError.invalidRequest("Writer workspace is outside the generation root")
        }
        let credentialPath = canonicalPath(kimiCredentialPath
            ?? NSHomeDirectory() + "/.kimi-code/credentials")
        let prior = readOnlyPriorWorkspace.map(canonicalPath)
        if let prior {
            guard engineer == .kimi, prior != workspace,
                  prior.hasPrefix(root + "/writer-runs/"),
                  prior.hasSuffix("/workspace") else {
                throw WorkshopError.invalidRequest("Prior session workspace is outside the generation root")
            }
        }
        for path in [profile, token, credentialPath] + (prior.map { [$0] } ?? []) {
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
        let profileWrites: String
        switch engineer {
        case .kimi:
            // Kimi's KIMI_CODE_HOME is a Workshop-owned disposable profile:
            // session storage, device state and its fs.watch live under it.
            // OAuth refresh replaces files inside the linked canonical dir.
            profileWrites = "(subpath \"\(profile)\") (subpath \"\(credentialPath)\")"
        default:
            profileWrites = "(subpath \"\(profile)/cache\") (subpath \"\(profile)/state\") (subpath \"\(profile)/data/devin/cli\") (subpath \"\(profile)/config/devin/cli\") (subpath \"\(userHome)/.local/share/devin/cli\") (literal \"\(userHome)/.local/share/fusion-codex-relay/.launch.lock\")"
        }
        // fs.watch()/vnode lookup stats every ancestor directory of the
        // watched path; the blanket root deny breaks watch on otherwise
        // allowed subpaths. Grant stat()-only access to the ancestors of the
        // writable subpaths — directory contents remain denied.
        var ancestors = Set<String>()
        for path in [run, profile] {
            var dir = (path as NSString).deletingLastPathComponent
            while dir.hasPrefix(root) {
                ancestors.insert(dir)
                guard dir != root else { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        let ancestorMetadata = ancestors.sorted()
            .map { "(literal \"\($0)\")" }.joined(separator: " ")
        text += """

        (deny file-read* (regex #"/user[.]token$"))
        (deny file-write*)
        (allow file-write* (subpath "\(run)") \(profileWrites) (literal "/dev/null"))
        (deny file-read* (subpath "\(root)"))
        (allow file-read* (subpath "\(run)") (subpath "\(profile)") (literal "\(token)") (literal "\(root)/bin/workshop-mcp"))
        """
        if let prior {
            // Kimi watches its old cwd while loading native history. The
            // parent needs stat-only access; the old workspace is read-only.
            let priorRun = (prior as NSString).deletingLastPathComponent
            text += "\n(allow file-read-metadata (literal \"\(priorRun)\"))"
            text += "\n(allow file-read* (subpath \"\(prior)\"))"
            text += "\n(deny file-read* (regex #\"/user[.]token$\"))"
        }
        if !ancestorMetadata.isEmpty {
            text += "\n(allow file-read-metadata \(ancestorMetadata))"
        }
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
        try reconcileKimiCredentialLink(
            home: home, profile: profile,
            target: NSHomeDirectory() + "/.kimi-code/credentials")
        // The OAuth reference is region/account-specific. Read only its
        // non-secret routing fields; the credential stays in the linked dir.
        let oauth = try kimiOAuthReference(path: NSHomeDirectory() + "/.kimi-code/config.toml")
        let dest = profile + "/config.toml"
        do {
            let config = """
            default_model = "kimi-code/k3"

            [providers."managed:kimi-code"]
            type = "kimi"
            api_key = ""
            base_url = "\(oauth.baseURL)"

            [providers."managed:kimi-code".oauth]
            storage = "file"
            key = "\(oauth.key)"
            oauth_host = "\(oauth.oauthHost)"

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

    struct KimiOAuthReference {
        let baseURL: String
        let key: String
        let oauthHost: String
    }

    /// A deliberately narrow TOML scanner. Do not import provider API keys or
    /// arbitrary user configuration into the Workshop-owned clean profile.
    static func kimiOAuthReference(path: String) throws -> KimiOAuthReference {
        let config = try String(contentsOfFile: path, encoding: .utf8)
        var section = ""
        var fields: [String: String] = [:]
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                    .replacingOccurrences(of: "\"", with: "")
                continue
            }
            guard section == "providers.managed:kimi-code"
                    || section == "providers.managed:kimi-code.oauth",
                  let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard value.first == "\"", value.last == "\"" else { continue }
            fields[section + "." + name] = String(value.dropFirst().dropLast())
        }
        let base = fields["providers.managed:kimi-code.base_url"] ?? ""
        let key = fields["providers.managed:kimi-code.oauth.key"] ?? ""
        let host = fields["providers.managed:kimi-code.oauth.oauth_host"] ?? ""
        guard ["https://api.kimi.ai/coding/v1", "https://api.kimi.com/coding/v1"].contains(base),
              ["https://auth.kimi.ai", "https://auth.kimi.com"].contains(host),
              key.hasPrefix("oauth/kimi-code"),
              key.dropFirst("oauth/".count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw WorkshopError.invalidRequest("Kimi OAuth reference is unavailable or unrecognized; review required")
        }
        return KimiOAuthReference(baseURL: base, key: key, oauthHost: host)
    }

    /// Older profiles copied credentials into a real directory. Preserve that
    /// directory before switching to the canonical credential reference.
    static func reconcileKimiCredentialLink(home: String, profile: String, target: String) throws {
        let fm = FileManager.default
        let link = profile + "/credentials"
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkshopError.invalidRequest("Canonical Kimi credentials directory is unavailable")
        }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
            guard existing == target else {
                throw WorkshopError.invalidRequest("Workshop Kimi credential link has drifted; review required")
            }
            return
        }
        var moved: String?
        if fm.fileExists(atPath: link, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw WorkshopError.invalidRequest("Workshop Kimi credential path is not a directory")
            }
            let backupRoot = home + "/backups"
            try fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
            let backup = backupRoot + "/kimi-credentials-" + UUID().uuidString.lowercased()
            try fm.moveItem(atPath: link, toPath: backup)
            moved = backup
        }
        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        } catch {
            if let moved { try? fm.moveItem(atPath: moved, toPath: link) }
            throw error
        }
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
        // The Fusion wrapper starts the relay even for --version. Probe the
        // underlying CLI so relay state cannot mask a healthy writer.
        spec.versionProbePath = NSHomeDirectory() + "/.local/bin/devin"
        spec.worktreeRoot = paths.home + "/worktrees"
        spec.mcpURL = paths.mcpURL
        return (spec, sb)
    }

    /// Kimi launch spec: `kimi acp` with KIMI_CODE_HOME profile, ACP mcpServers.
    /// Concurrency: at most ONE Kimi process — serialized by the service's
    /// single-turn-per-(task,engineer) guard plus a per-engineer limit of 1.
    public static func kimiSpec(paths: Paths, worktree: String) throws -> HarnessLaunchSpec {
        let profile = try kimiProfile(home: paths.home)
        var env = kimiEnvironment(profile: profile, source: ProcessInfo.processInfo.environment)
        env["WORKSHOP_MCP_PATH"] = paths.mcpBridge
        env["WORKSHOP_TOKEN_KIMI"] = paths.home + "/profiles/kimi/token"
        if let rt = paths.runtimeDir { env["WORKSHOP_RUNTIME_DIR"] = rt }
        let sb = profile + "/isolation.sb"
        try devinSandboxProfile(workshopHome: paths.home, worktree: worktree, destination: sb)
        var spec = HarnessLaunchSpec(
            engineer: .kimi, executable: "/usr/bin/sandbox-exec", args: ["-f", sb, paths.kimiBinary, "--auto", "acp"],
            env: env, cwd: worktree,
            mcpInjection: .acpSessionParam,
            qualifiedVersion: "0.42.0", modelSelection: "kimi-code/k3")
        spec.worktreeRoot = paths.home + "/worktrees"
        spec.versionProbePath = paths.kimiBinary
        spec.sandboxProfilePath = sb
        spec.mcpURL = paths.mcpURL
        return spec
    }
}
