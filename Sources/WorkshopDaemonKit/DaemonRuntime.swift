import CoreServices
import Foundation
import Security
import WorkshopAdapters
import WorkshopCore
import WorkshopIPC
import WorkshopMCP
import WorkshopService
import WorkshopStore

/// Shared daemon wiring used by `workshop-daemon` and the live smoke tests.
/// Owns WORKSHOP_HOME layout, capability tokens, engineers.json loading,
/// adapter selection, the IPC server, and event broadcasting.
public final class DaemonRuntime: @unchecked Sendable {
    public let home: String
    public let runtimeDir: String
    public let socketPath: String
    public let service: CollaborationService
    public let server: IPCServer
    /// Streamable HTTP MCP endpoint on 127.0.0.1; bound in init, started in
    /// `start()`. Sessions are in-memory — a restart forces re-initialization.
    public let mcpServer: MCPHTTPServer
    public var mcpURL: String { mcpServer.url }
    public let adapters: [EngineerAdapter]
    /// config/capabilities.json (G-E5); injected into capability-aware lanes.
    public let capabilityStore: CapabilityStore
    private var broadcastTask: Task<Void, Never>?
    private var canaryTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?

    public struct EngineerConfig: Codable {
        public var id: String
        public var adapter_kind: String?
        public var qualified_binary_version: String?
        public var model_selection: String?
        public var executable: String?
        /// §10 capacity policy (ADR 0012).
        public var budget: Budget?
        /// Whether the managed runtime lane may take over when the native
        /// lane fails startup (default true for kimi and deepseek; devin has
        /// no managed lane).
        public var managed_fallback: Bool?
        /// Optional model override for the managed lane.
        public var managed_model: String?
    }
    public struct Budget: Codable {
        public var daily_token_cap: Int?
        public var reserve_per_turn: Int?
        public var low_pct: Int?
        public var critical_pct: Int?
        public var hysteresis_pct: Int?
    }
    public struct EngineersFile: Codable {
        public var schema_version: Int?
        public var engineers: [EngineerConfig]?
        public var mcp_bridge: String?

        public init() { schema_version = nil; engineers = nil; mcp_bridge = nil }

        public func engineer(_ id: EngineerID) -> EngineerConfig? {
            engineers?.first { $0.id == id.rawValue }
        }
    }

    /// `${DARWIN_USER_TEMP_DIR}/workshop` or WORKSHOP_RUNTIME_DIR.
    public static func defaultRuntimeDir() -> String {
        IPCServer.defaultRuntimeDir()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[workshop-daemon] \(message)\n".utf8))
    }

    /// Build the full runtime: directories, tokens, config, adapters, service,
    /// and the IPC server (not yet listening — call `start()`).
    public init(home: String, runtimeDir: String? = nil,
                env: [String: String] = ProcessInfo.processInfo.environment,
                ownExecutable: String = CommandLine.arguments[0],
                fakeConfigurator: (@Sendable (FakeAdapter) -> Void)? = nil) throws {
        self.home = home
        let fm = FileManager.default

        // Monotonic per-step timings logged once by `start()` (one summary
        // line plus any step over 500 ms) so slow-start regressions are
        // visible in the daemon log.
        var marks: [(name: String, ms: Int64)] = []
        var lapAt = ContinuousClock.now
        func lap(_ name: String) {
            let now = ContinuousClock.now
            let d = now - lapAt
            marks.append((name, Int64(Double(d.components.seconds) * 1000
                + Double(d.components.attoseconds) / 1e15)))
            lapAt = now
        }

        for sub in ["db", "profiles", "sessions/deepseek", "sessions/kimi", "worktrees",
                    "artifacts", "diagnostics", "config"] {
            try fm.createDirectory(atPath: home + "/" + sub,
                                   withIntermediateDirectories: true)
        }

        // Per-engineer capability tokens (§9.3): 32 random bytes hex, 0600.
        for engineer in EngineerID.allCases {
            let dir = home + "/profiles/" + engineer.rawValue
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let tokenPath = dir + "/token"
            if !fm.fileExists(atPath: tokenPath) {
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = bytes.withUnsafeMutableBytes {
                    SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
                }
                let token = bytes.map { String(format: "%02x", $0) }.joined()
                try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
                chmod(tokenPath, 0o600)
            }
        }

        // Codex entry point token (§9.3): same generation/permissions as the
        // engineer tokens; preserved across restarts.
        let codexDir = home + "/profiles/codex"
        try fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        let codexTokenPath = codexDir + "/token"
        if !fm.fileExists(atPath: codexTokenPath) {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            try token.write(toFile: codexTokenPath, atomically: true, encoding: .utf8)
            chmod(codexTokenPath, 0o600)
        }

        // Keep the bridge at a stable, executable path outside the app bundle.
        // Launching a nested app resource can stall in dyld after a bundle swap.
        lap("dirs+tokens")
        let bridgePath = Self.installBridgeCopy(home: home, env: env,
                                                ownExecutable: ownExecutable)
        lap("bridgeCopy")

        let runtime = runtimeDir ?? IPCServer.defaultRuntimeDir()
        self.runtimeDir = runtime
        try fm.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        chmod(runtime, 0o700)
        let socket = runtime + "/service.sock"
        self.capabilityStore = CapabilityStore(path: home
            + "/config/capabilities.json")
        precondition(socket.utf8.count < 100, "socket path too long: \(socket)")
        self.socketPath = socket

        // engineers.json: created from the committed template on first run.
        let engineersPath = home + "/config/engineers.json"
        if !fm.fileExists(atPath: engineersPath) {
            let templatePath = Self.templatePath()
            try? fm.copyItem(atPath: templatePath, toPath: engineersPath)
        }
        let engineersConfig: EngineersFile =
            (try? Data(contentsOf: URL(fileURLWithPath: engineersPath)))
            .flatMap { try? JSONDecoder().decode(EngineersFile.self, from: $0) }
            ?? EngineersFile()

        // Adapter mode: live for the installed home, fake elsewhere. Fake
        // adapters must never run against the installed home — a daemon
        // restarted there with fakes would inject scripted replies into live
        // tasks (G-D8).
        let installedHome = ProfileBuilder.canonicalPath(
            env["WORKSHOP_INSTALLED_HOME_OVERRIDE"]
                ?? NSHomeDirectory() + "/Library/Application Support/Workshop")
        let canonicalHome = ProfileBuilder.canonicalPath(home)
        let adaptersMode = env["WORKSHOP_ADAPTERS"]
            ?? (canonicalHome == installedHome ? "live" : "fake")
        func isFake(_ engineer: EngineerID) -> Bool {
            if adaptersMode == "live" { return false }
            if adaptersMode == "fake" { return true }
            if adaptersMode.hasPrefix("mixed:") {
                let list = adaptersMode.dropFirst("mixed:".count)
                for entry in list.split(separator: ",") {
                    let kv = entry.split(separator: "=")
                    if kv.count == 2, kv[0] == Substring(engineer.rawValue) {
                        return kv[1] == "fake"
                    }
                }
            }
            return false
        }

        if EngineerID.allCases.contains(where: isFake),
           canonicalHome == installedHome,
           env["WORKSHOP_ALLOW_FAKE_ON_INSTALLED_HOME"] != "1" {
            Self.log("Refusing fake adapters against the installed Workshop home")
            throw WorkshopError.invalidRequest(
                "Refusing fake adapters against the installed Workshop home; "
                + "set WORKSHOP_ADAPTERS=live or "
                + "WORKSHOP_ALLOW_FAKE_ON_INSTALLED_HOME=1 for a deliberate test")
        }

        // Bridge copy failed or was unavailable: live adapters fail visibly.
        if bridgePath == nil, adaptersMode != "fake" {
            Self.log("workshop-mcp not found: set WORKSHOP_MCP_PATH or place "
                     + "workshop-mcp next to the daemon executable")
        }

        func expandHome(_ path: String?) -> String? {
            guard let path else { return nil }
            if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
            return path
        }

        // MCP over Streamable HTTP (127.0.0.1). Bound here — before adapters
        // are built — so the launch specs can carry the concrete URL. The
        // service is installed into `serviceBox` once it exists below; auth
        // closures run per request so revocations take effect immediately.
        let mcpPort: UInt16 = env["WORKSHOP_MCP_PORT"].flatMap(UInt16.init)
            ?? (canonicalHome == installedHome ? 47831 : 0)
        var mcpConfig = MCPHTTPServer.Config()
        mcpConfig.port = mcpPort
        let serviceBox = ServiceBox()
        let mcpServer = MCPHTTPServer(
            config: mcpConfig, serverVersion: "0",
            authenticate: { token in
                guard let service = serviceBox.service else {
                    throw WorkshopError.invalidRequest("service not ready")
                }
                return try await service.authenticate(token: token)
            },
            authorize: { token, method, params in
                guard let service = serviceBox.service else {
                    throw WorkshopError.invalidRequest("service not ready")
                }
                try await service.authorizeWriterRequest(token: token,
                                                         method: method,
                                                         params: params)
            },
            callTool: { method, args, principal in
                guard let service = serviceBox.service else {
                    throw WorkshopError.invalidRequest("service not ready")
                }
                return try await service.callTool(method, args: args,
                                                  principal: principal)
            })
        mcpServer.logger = { Self.log($0) }
        try mcpServer.bind()
        self.mcpServer = mcpServer
        Self.log("mcp endpoint bound at \(mcpServer.url)")
        lap("mcpBind")

        let paths = ProfileBuilder.Paths(
            home: home,
            devinBinary: expandHome(engineersConfig.engineer(.devin)?.executable)
                ?? NSHomeDirectory() + "/.local/bin/devin",
            kimiBinary: expandHome(engineersConfig.engineer(.kimi)?.executable)
                ?? NSHomeDirectory() + "/.kimi-code/bin/kimi",
            mcpBridge: bridgePath ?? "<missing workshop-mcp>",
            runtimeDir: runtime, mcpURL: mcpServer.url)

        // Managed-lane plumbing (D-b): tool execution and checkpoint
        // summaries resolve the service per call through serviceBox, so
        // managed adapters built before the service still bind correctly.
        func managedToolExecutor(_ engineer: EngineerID)
            -> @Sendable (String, JSONValue) async throws -> String {
            { name, args in
                if let dir = ProcessInfo.processInfo.environment["WORKSHOP_DIAG_DIR"],
                   let data = try? JSONEncoder().encode(
                    JSONValue.object(["tool": .string(name), "args": args])) {
                    let p = dir + "/tool-calls.log"
                    let line = String(decoding: data, as: UTF8.self) + "\n"
                    if let fh = FileHandle(forWritingAtPath: p) {
                        fh.seekToEndOfFile(); fh.write(Data(line.utf8)); fh.closeFile()
                    } else {
                        FileManager.default.createFile(atPath: p, contents: Data(line.utf8))
                    }
                }
                guard WorkshopToolCatalog.method(for: name) != nil else {
                    return #"{"error":"unknown tool"}"#
                }
                guard let service = serviceBox.service else {
                    return #"{"error":"service not ready"}"#
                }
                do {
                    let result = try await service.callTool(
                        name, args: args, principal: .engineer(engineer))
                    let data = try? JSONEncoder().encode(result)
                    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                } catch let error as WorkshopRPCError {
                    return #"{"error":"\#(error.message)"}"#
                }
            }
        }
        // Managed-history compaction summary comes from the latest valid
        // checkpoint — no model call.
        func managedCheckpointSummary(_ engineer: EngineerID)
            -> @Sendable (TaskID) async -> String? {
            { taskID in
                guard let service = serviceBox.service,
                      let cp = try? await service.loadValidCheckpoint(
                        taskID: taskID, engineerID: engineer) else { return nil }
                return cp.content
            }
        }
        // The managed lane's exec tool runs under a per-generation sandbox
        // profile written next to the fenced workspace.
        let managedSandboxProfile: @Sendable (String) throws -> String = { ws in
            let dest = (ws as NSString).deletingLastPathComponent + "/managed.sb"
            try ProfileBuilder.managedSandboxProfile(workshopHome: home,
                                                     worktree: ws,
                                                     destination: dest)
            return dest
        }
        let laneObserver: @Sendable (TaskID, EngineerID, String) async -> Void =
            { taskID, engineer, lane in
                await serviceBox.service?.recordLane(taskID: taskID,
                                                     engineer: engineer,
                                                     lane: lane)
            }
        // Kimi's access tokens expire ~15 min after the CLI refreshes them;
        // the CLI owns the rotating refresh grant, so we only ever ask the
        // CLI to refresh (one minimal prompt, managed lane only).
        let kimiRefresher: @Sendable (String) async throws
            -> KimiCLIRefresh.RefreshReport = { binary in
            try await KimiCLIRefresh.run(kimiBinary: binary, paths: paths,
                                         log: { Self.log($0) })
        }
        self.kimiRefreshHook = kimiRefresher
        self.kimiBinaryPath = paths.kimiBinary
        func managedAdapter(_ engineer: EngineerID,
                            keyReader: @escaping @Sendable () async throws -> String,
                            provider: ManagedProvider) -> ManagedRuntimeAdapter {
            let adapter = ManagedRuntimeAdapter(
                engineer: engineer, provider: provider,
                transport: URLSessionHTTPTransport(),
                sessionsDir: home + "/sessions/" + engineer.rawValue,
                keyReader: keyReader,
                workshopToolExecutor: managedToolExecutor(engineer),
                sandboxProfileProvider: managedSandboxProfile,
                localTools: true)
            adapter.checkpointSummary = managedCheckpointSummary(engineer)
            return adapter
        }

        func liveAdapter(_ engineer: EngineerID,
                         worktreeHint: String) -> EngineerAdapter? {
            // Devin and Kimi both need the bridge for their Workshop tools.
            if engineer != .deepseek, bridgePath == nil {
                return UnconfiguredAdapter(engineer: engineer,
                                           reason: "unavailable: workshop-mcp not found")
            }
            do {
                switch engineer {
                case .devin:
                    // No managed lane: the Fusion relay exposes no
                    // completions route.
                    let model = engineersConfig.engineer(.devin)?.model_selection
                        ?? "fusion-claude-fable-5-1-medium-sidekick-swe-2-medium"
                    let (spec, _) = try ProfileBuilder.devinSpec(
                        paths: paths, worktree: worktreeHint, model: model)
                    return ACPHarnessAdapter(spec: spec)
                case .kimi:
                    let cfg = engineersConfig.engineer(.kimi)
                    let spec = try ProfileBuilder.kimiSpec(paths: paths,
                                                           worktree: worktreeHint)
                    let native: EngineerAdapter = ACPHarnessAdapter(spec: spec)
                    guard cfg?.managed_fallback ?? true else { return native }
                    let managed = managedAdapter(
                        .kimi,
                        keyReader: { [kimiRefresher] in
                            try await KimiOAuthCredential.readAccessToken(
                                kimiBinary: paths.kimiBinary,
                                refreshViaCLI: kimiRefresher) },
                        provider: .kimi(model: cfg?.managed_model ?? "k3"))
                    return LaneSelectingAdapter(engineer: .kimi, native: native,
                                                managed: managed,
                                                laneObserver: laneObserver)
                case .deepseek:
                    let cfg = engineersConfig.engineer(.deepseek)
                    let managed = managedAdapter(
                        .deepseek,
                        keyReader: { try DeepSeekAdapter.readCredential() },
                        provider: .deepseek(
                            model: cfg?.managed_model ?? cfg?.model_selection
                                ?? DeepSeekAdapter.defaultModel))
                    return LaneSelectingAdapter(engineer: .deepseek, native: nil,
                                                managed: managed,
                                                laneObserver: laneObserver)
                }
            } catch {
                Self.log("live adapter \(engineer.rawValue) setup failed: "
                         + error.localizedDescription)
                return nil
            }
        }

        let built: [EngineerAdapter] = EngineerID.allCases.map { engineer in
            isFake(engineer) ? { () -> EngineerAdapter in
                let fake = FakeAdapter(engineer: engineer)
                fakeConfigurator?(fake)
                return fake
            }()
                : (liveAdapter(engineer, worktreeHint: home + "/worktrees/_default")
                    ?? UnconfiguredAdapter(engineer: engineer))
        }
        self.adapters = built
        self.adaptersModeLive = Set(EngineerID.allCases.filter { !isFake($0) })
        lap("adapters")

        let dbPath = home + "/db/workshop.sqlite"
        var policies: [EngineerID: CapacityPolicy] = [:]
        for engineer in EngineerID.allCases {
            if let b = engineersConfig.engineer(engineer)?.budget {
                policies[engineer] = CapacityPolicy(
                    dailyTokenCap: b.daily_token_cap,
                    reservePerTurn: b.reserve_per_turn ?? 30_000,
                    lowPct: b.low_pct ?? 20, criticalPct: b.critical_pct ?? 10,
                    hysteresisPct: b.hysteresis_pct ?? 5)
            }
        }
        let service = try CollaborationService(databasePath: dbPath,
                                               adapters: built, homeDir: home,
                                               capacityPolicies: policies)
        self.service = service
        serviceBox.service = service
        Self.log("opened database at \(dbPath)")
        lap("serviceInit")
        service.deepLinkHandlerVerified = Self.deepLinkRegistered()
        self.buildID = Self.buildID(executable: ownExecutable)
        lap("reg+buildID")

        // Register the resolved DeepSeek key with the Redactor (compare-only;
        // never logged).
        if let key = try? DeepSeekAdapter.readCredential() {
            Redactor.shared.registerSecret(key)
        }
        self.pendingHome = home

        let server = try IPCServer(socketPath: socket)
        self.server = server
        // A successful session open means the CLI just touched its grant;
        // refresh that engineer's canary immediately instead of waiting for
        // the 30-minute sweep.
        service.sessionOpenedHook = { [weak self] engineer in
            guard let self else { return }
            let (state, detail) = await CredentialCanary.check(
                engineer: engineer, home: self.home)
            await service.recordCredentialStatus(engineer: engineer,
                                                 state: state.rawValue,
                                                 detail: detail)
        }
        applyCapabilities()
        lap("applyCapabilities")
        let userTokenPath = runtime + "/user.token"
        guard (try? fm.destinationOfSymbolicLink(atPath: userTokenPath)) == nil else {
            throw WorkshopError.invalidRequest("User token path is a symlink")
        }
        if !fm.fileExists(atPath: userTokenPath) {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw WorkshopError.invalidRequest("Unable to generate desktop authentication")
            }
            try random.map { String(format: "%02x", $0) }.joined().write(toFile: userTokenPath, atomically: true, encoding: .utf8)
            chmod(userTokenPath, 0o600)
        }
        let userToken = try String(contentsOfFile: userTokenPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard userToken.count == 64 else { throw WorkshopError.invalidRequest("Invalid desktop authentication file") }
        server.requiresAuthentication = true
        server.authenticator = { token in
            if token == userToken { return .user }
            return try await service.authenticate(token: token)
        }
        server.requestAuthorizer = { token, method, params in
            try await service.authorizeWriterRequest(token: token, method: method, params: params)
        }
        server.handler = { method, params, principal in
            if principal != .user && !method.hasPrefix("workshop_") {
                throw WorkshopError.invalidRequest("Desktop command requires authenticated user")
            }
            switch method {
            case "workshop.promoteWriterSnapshot":
                try await service.promoteWriterSnapshot(id: params?["writer_id"]?.stringValue ?? "",
                    verifiedDigest: params?["verified_digest"]?.stringValue ?? "", principal: principal)
                return .object(["accepted": .bool(true)])
            case "workshop.reloadCapabilities":
                self.capabilityStore.reload()
                self.applyCapabilities()
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.health:
                return .object([
                    "status": .string("ok"),
                    "protocol_version": .number(Double(WorkshopProtocol.version)),
                    "build": .string(self.buildID ?? ""),
                ])
            case WorkshopProtocol.stopBackground:
                // Pause every Working task, answer the client, then exit. The
                // LaunchAgent registration stays; KeepAlive=false keeps it idle.
                let tasks = (try? await service.listTasks()) ?? []
                for task in tasks where task.state == .working {
                    try? await service.pauseTask(taskID: task.id, principal: .user)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    Self.log("stop background work requested; exiting")
                    Foundation.exit(0)
                }
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.createTask:
                let request = try (params ?? .object([:])).decode(as: CreateTaskRequest.self)
                return try .from(try await service.createTask(request))
            case WorkshopProtocol.listTasks:
                return try .from(try await service.listTasks())
            case WorkshopProtocol.readActivity:
                return try .from(try await service.readActivity(
                    TaskID(params?["task_id"]?.stringValue ?? ""),
                    afterSeq: params?["after_seq"]?.intValue ?? 0,
                    limit: Int(params?["limit"]?.intValue ?? 200)))
            case WorkshopProtocol.getTask:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try .from(try await service.getTask(id))
            case WorkshopProtocol.listArtifacts:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try .from(try await service.listArtifacts(id))
            case WorkshopProtocol.listUsage:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try .from(try await service.listUsage(id))
            case WorkshopProtocol.readMessages:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                let afterSeq = params?["after_seq"]?.intValue ?? 0
                let limit = Int(params?["limit"]?.intValue ?? 500)
                return try .from(try await service.readMessages(id, afterSeq: afterSeq,
                    limit: limit,
                    includeSummaries: params?["include_summaries"].flatMap {
                        if case .bool(let b) = $0 { return b }
                        return nil
                    } ?? false))
            case WorkshopProtocol.postMessage:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                let body = params?["body"]?.stringValue ?? ""
                return try .from(try await service.postMessage(
                    taskID: id, body: body, principal: principal,
                    idempotencyKey: params?["idempotency_key"]?.stringValue))
            case WorkshopProtocol.listEngineers:
                return try .from(await service.listEngineers())
            case WorkshopProtocol.listProposals:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try .from(try await service.listProposals(id))
            case WorkshopProtocol.listReports:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try .from(try await service.listReports(id))
            case WorkshopProtocol.listDecisions:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try .from(try await service.listDecisions(id))
            case WorkshopProtocol.approveArchitecture:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                try await service.approveArchitecture(
                    taskID: id,
                    reportRevision: Int(params?["report_revision"]?.intValue ?? 0),
                    scope: params?["scope"]?.stringValue, principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.requestChanges:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                try await service.requestChanges(
                    taskID: id,
                    reportRevision: Int(params?["report_revision"]?.intValue ?? 0),
                    comment: params?["comment"]?.stringValue ?? "",
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.chooseAlternative:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                try await service.chooseAlternative(
                    taskID: id,
                    reportRevision: Int(params?["report_revision"]?.intValue ?? 0),
                    alternativeIndex: Int(params?["alternative_index"]?.intValue ?? 0),
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.pauseTask:
                try await service.pauseTask(
                    taskID: TaskID(params?["task_id"]?.stringValue ?? ""),
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.resumeTask:
                try await service.resumeTask(
                    taskID: TaskID(params?["task_id"]?.stringValue ?? ""),
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.cancelTask:
                try await service.cancelTask(
                    taskID: TaskID(params?["task_id"]?.stringValue ?? ""),
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.acceptTask:
                try await service.acceptTask(
                    taskID: TaskID(params?["task_id"]?.stringValue ?? ""),
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.convertToResearch:
                try await service.convertToResearch(
                    taskID: TaskID(params?["task_id"]?.stringValue ?? ""),
                    principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.reassignSubtask:
                let sub = SubtaskID(params?["subtask_id"]?.stringValue ?? "")
                guard let ownerRaw = params?["owner"]?.stringValue,
                      let owner = EngineerID(rawValue: ownerRaw) else {
                    throw WorkshopError.invalidRequest("owner required")
                }
                try await service.reassignSubtask(subtaskID: sub, newOwner: owner,
                                                  principal: principal)
                return .object(["ok": .bool(true)])
            case WorkshopProtocol.diagnostics:
                return await service.diagnostics()
            case WorkshopProtocol.readMessagePage:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                let beforeSeq = params?["before_seq"]?.intValue
                let limit = Int(params?["limit"]?.intValue ?? 500)
                return try .from(try await service.readMessagePage(
                    id, beforeSeq: beforeSeq, limit: limit,
                    includeSummaries: params?["include_summaries"].flatMap {
                        if case .bool(let b) = $0 { return b }
                        return nil
                    } ?? false))
            case WorkshopProtocol.recoverySummary:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                return try await service.recoverySummary(taskID: id)
                    .map(JSONValue.string) ?? .null
            case WorkshopProtocol.search:
                let query = params?["query"]?.stringValue ?? ""
                let limit = Int(params?["limit"]?.intValue ?? 50)
                return try .from(try await service.search(query: query, limit: limit))
            case WorkshopProtocol.exportTask:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                guard let dest = params?["dest_dir"]?.stringValue else {
                    throw WorkshopError.invalidRequest("dest_dir required")
                }
                return try await service.exportTask(taskID: id, destDir: dest)
            case WorkshopProtocol.backup:
                guard let dest = params?["dest_dir"]?.stringValue else {
                    throw WorkshopError.invalidRequest("dest_dir required")
                }
                return try await service.backup(destDir: dest)
            default:
                if method.hasPrefix("workshop_"),
                   WorkshopToolCatalog.method(for: method) != nil
                    || ["workshop_create_task"].contains(method) {
                    return try await service.callTool(method, args: params ?? .object([:]),
                                                      principal: principal)
                }
                throw WorkshopError.methodNotFound(method)
            }
        }
        server.replayEvents = { [service] afterSeq in
            var result: [OutboxEvent] = []
            var error: Error?
            let sem = DispatchSemaphore(value: 0)
            Task {
                do { result = try await service.outboxEvents(afterSeq: afterSeq) }
                catch let e { error = e }
                sem.signal()
            }
            sem.wait()
            if let error {
                Self.log("replayEvents failed: \(error.localizedDescription)")
                return []
            }
            return result
        }
        lap("ipcHandlers")
        self.startupMarks = marks
        self.startupLast = lapAt
        self.startupInitMs = Self.msSince(startupT0)
    }

    /// Build identity reported by workshop.health — the bundle's
    /// CFBundleVersion when running packaged ("bundle:<ver>"), else the
    /// executable's mtime+size ("bin:<mtime>-<size>"). The app compares its own
    /// value and only warns when both sides carry a bundle version.
    private var buildID: String?

    /// Start-up timing state (see the `startup:` log line written by start()).
    private let startupT0 = ContinuousClock.now
    private var startupLast = ContinuousClock.now
    private var startupMarks: [(name: String, ms: Int64)] = []
    private var startupInitMs: Int64 = 0
    private var startupListenMs: Int64 = 0

    /// Test seam: replaces the post-listen DeepSeek balance refresh.
    var balanceRefresh: (@Sendable () async -> Void)?
    /// Test seam: replaces the credential canary sweep on start.
    var canarySweep: (@Sendable (String, CollaborationService,
                               Set<EngineerID>) async -> Void)?

    private func lap(_ name: String) {
        let now = ContinuousClock.now
        let d = now - startupLast
        startupMarks.append((name, Int64(Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15)))
        startupLast = now
    }

    private static func msSince(_ t: ContinuousClock.Instant) -> Int64 {
        let d = ContinuousClock.now - t
        return Int64(Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15)
    }

    public static func buildID(executable: String) -> String {
        let plist = (executable as NSString).deletingLastPathComponent
            + "/../Info.plist"
        if let info = NSDictionary(contentsOfFile: plist),
           let version = info["CFBundleVersion"] as? String {
            return "bundle:\(version)"
        }
        if let attrs = try? FileManager.default
            .attributesOfItem(atPath: executable),
           let mtime = attrs[.modificationDate] as? Date,
           let size = attrs[.size] as? Int64 {
            return "bin:\(Int(mtime.timeIntervalSince1970))-\(size)"
        }
        return "unknown"
    }

    /// True when Launch Services resolves `workshop://` to this app's bundle id.
    static func deepLinkRegistered() -> Bool {
        guard let handler = LSCopyDefaultHandlerForURLScheme("workshop" as CFString)?
            .takeRetainedValue() as? String else { return false }
        return handler == "ai.maapu.workshop"
    }

    /// Atomically refresh the stable MCP executable used by Codex and peers.
    static func installBridgeCopy(home: String, env: [String: String],
                                  ownExecutable: String) -> String? {
        let fm = FileManager.default
        guard let source = resolveMCPBridge(env: env, ownExecutable: ownExecutable) else {
            return nil
        }
        let binDir = home + "/bin"
        let destination = binDir + "/workshop-mcp"
        let staging = binDir + "/.workshop-mcp-\(UUID().uuidString)"
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: source, toPath: staging)
            guard chmod(staging, 0o755) == 0,
                  rename(staging, destination) == 0 else {
                throw WorkshopError.invalidRequest("Cannot install Workshop MCP bridge")
            }
            Self.log("bridge copy \(destination) from \(source)")
            return destination
        } catch {
            try? fm.removeItem(atPath: staging)
            Self.log("bridge copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Committed template path: development checkout layout relative to this
    /// file, falling back to a bundle-adjacent Configuration directory.
    static func templatePath() -> String {
        let dev = (#filePath as NSString)
            .deletingLastPathComponent + "/../../Configuration/engineers.template.json"
        if FileManager.default.fileExists(atPath: (dev as NSString).standardizingPath) {
            return (dev as NSString).standardizingPath
        }
        return (CommandLine.arguments[0] as NSString).deletingLastPathComponent
            + "/../Configuration/engineers.template.json"
    }

    /// workshop-mcp discovery (fix 4): WORKSHOP_MCP_PATH env, else a sibling
    /// `workshop-mcp` next to `ownExecutable`.
    public static func resolveMCPBridge(env: [String: String],
                                        ownExecutable: String) -> String? {
        let fm = FileManager.default
        if let path = env["WORKSHOP_MCP_PATH"], !path.isEmpty,
           fm.isExecutableFile(atPath: path) {
            return path
        }
        let sibling = (ownExecutable as NSString).deletingLastPathComponent
            + "/workshop-mcp"
        if fm.isExecutableFile(atPath: sibling) { return sibling }
        return nil
    }

    /// G-E5: inject the capability-record lookup into live lanes and flag
    /// binary drift (advisory — the recorded qualification still stands).
    private func applyCapabilities() {
        for subject in adapters.compactMap({ $0 as? CapabilityAwareAdapter })
                               .flatMap(\.capabilitySubjects)
            where adaptersModeLive.contains(subject.engineer) {
            subject.capabilityLookup = { [capabilityStore] identity in
                capabilityStore.record(for: identity)
            }
            if let identity = subject.qualificationIdentity,
               let record = capabilityStore.record(for: identity),
               let recorded = record.binarySHA256,
               let binary = subject.qualificationBinaryPath,
               CapabilityStore.sha256(file: binary) != recorded {
                subject.binaryDriftNotice =
                    "binary changed since qualification (UNTESTED)"
                let engineer = subject.engineer
                Task { await service.markBinaryDrifted(engineer) }
            }
        }
    }

    /// Listen on the socket, broadcast events, and
    /// start service recovery/dispatch.
    private var pendingHome: String?
    private var adaptersModeLive: Set<EngineerID> = []
    /// Kimi's grant is refreshed only by the Kimi CLI itself (rotating
    /// refresh token); the hook spawns `kimi acp` once, zero inference.
    private var kimiRefreshHook: (@Sendable (String) async throws
        -> KimiCLIRefresh.RefreshReport)?
    private var kimiBinaryPath: String?

    public func start() async throws {
        // Listen first: the desktop app only probes the socket for a few
        // seconds after launch, so all slow work runs after the UDS is
        // accepting connections.
        try server.start()
        try mcpServer.start()
        lap("listen")
        startupListenMs = Self.msSince(startupT0)
        let mcpInfo = String(decoding: try JSONEncoder().encode(JSONValue.object([
            "url": .string(mcpServer.url),
            "catalog_version": .number(Double(WorkshopToolCatalog.catalogVersion)),
            "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "started_at": .string(WorkshopTime.string(Date())),
        ])), as: UTF8.self)
        let mcpInfoPath = runtimeDir + "/mcp.json"
        try mcpInfo.write(toFile: mcpInfoPath, atomically: true, encoding: .utf8)
        chmod(mcpInfoPath, 0o600)
        Self.log("mcp endpoint \(mcpServer.url)")
        Self.log("listening on \(socketPath)")
        if let home = pendingHome {
            // Bounded balance probe (one GET /user/balance, ≤ every 10 min).
            await service.setBalanceProbe { engineer in
                guard engineer == .deepseek else { return nil }
                return await DeepSeekAdapter.balanceProbe(home: home,
                                                        observedAt: Date())
            }
            pendingHome = nil
        }
        await service.installSleepWakeHooks()
        lap("probes+hooks")
        if let refresh = balanceRefresh {
            Task.detached { await refresh() }
        } else if adaptersModeLive.contains(.deepseek) {
            // Network call (≤10 s) — must not block the listener.
            Task.detached { [service] in
                await service.refreshDeepSeekBalance()
            }
        }
        broadcastTask = Task.detached { [service, server] in
            for await event in await service.makeEventStream() {
                server.broadcastEvent(event)
            }
        }
        // G-E5: pick up qualification records written by `qualify` runs.
        capabilityStore.reload()
        applyCapabilities()
        let qualified = capabilityStore.load()
            .filter { $0.qualified }
            .map { $0.engineer.rawValue + "/" + $0.lane }
            .sorted().joined(separator: ", ")
        Self.log("capabilities: \(capabilityStore.load().count) records"
            + (qualified.isEmpty ? "" : "; qualified: \(qualified)"))
        lap("capabilities")
        // G-D1: zero-inference credential canaries at start and every 30 min.
        // The first sweep is detached too: CLI canary checks are slow.
        let liveEngineers = adaptersModeLive
        let sweep = canarySweep ?? { home, service, only in
            await CredentialCanary.runAll(home: home, service: service,
                                          only: only)
        }
        canaryTask = Task.detached { [weak self] in
            guard let self else { return }
            await sweep(self.home, self.service, liveEngineers)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard !Task.isCancelled else { return }
                await sweep(self.home, self.service, liveEngineers)
            }
        }
        await service.start()
        lap("serviceStart")
        // Generation retention sweep (decision D-e): once after recovery,
        // then every ten minutes.
        if let report = await service.pruneGenerations(),
           report.deletedDirs > 0 {
            Self.log("pruned \(report.deletedDirs) generation dirs "
                     + "(\(report.bytes / 1_048_576) MB)")
        }
        lap("prune")
        pruneTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard let self else { return }
                if let report = await self.service.pruneGenerations(),
                   report.deletedDirs > 0 {
                    Self.log("pruned \(report.deletedDirs) generation dirs "
                             + "(\(report.bytes / 1_048_576) MB)")
                }
            }
        }
        Self.log("startup: init \(startupInitMs) ms, listen after "
                 + "\(startupListenMs) ms, ready after "
                 + "\(Self.msSince(startupT0)) ms")
        for mark in startupMarks where mark.ms > 500 {
            Self.log("startup step \(mark.name): \(mark.ms) ms")
        }
    }

    public func shutdown() async {
        broadcastTask?.cancel()
        canaryTask?.cancel()
        pruneTask?.cancel()
        await service.shutdown()
        server.stop()
        mcpServer.stop()
        try? FileManager.default.removeItem(atPath: runtimeDir + "/mcp.json")
    }
}

/// Late binding for the CollaborationService: the MCP HTTP server must bind
/// before adapters are built (they embed its URL), but its auth closures call
/// the service, which exists only after the adapters. Resolved per request.
final class ServiceBox: @unchecked Sendable {
    var service: CollaborationService?
}
