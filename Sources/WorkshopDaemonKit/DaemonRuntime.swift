import CoreServices
import Foundation
import Security
import WorkshopAdapters
import WorkshopCore
import WorkshopIPC
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
    public let adapters: [EngineerAdapter]
    private var broadcastTask: Task<Void, Never>?

    public struct EngineerConfig: Codable {
        public var id: String
        public var adapter_kind: String?
        public var qualified_binary_version: String?
        public var model_selection: String?
        public var executable: String?
        /// §10 capacity policy (ADR 0012).
        public var budget: Budget?
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
                ownExecutable: String = CommandLine.arguments[0]) throws {
        self.home = home
        let fm = FileManager.default

        for sub in ["db", "profiles", "sessions/deepseek", "worktrees",
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

        // Stable bridge path (§4.5): ~/.codex/config.toml points at
        // <home>/bin/workshop-mcp; re-point it at every start so rebuilds
        // never leave a stale path behind.
        Self.installBridgeSymlink(home: home, ownExecutable: ownExecutable)

        let runtime = runtimeDir ?? IPCServer.defaultRuntimeDir()
        self.runtimeDir = runtime
        try fm.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        chmod(runtime, 0o700)
        let socket = runtime + "/service.sock"
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

        let adaptersMode = env["WORKSHOP_ADAPTERS"] ?? "fake"
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

        // workshop-mcp discovery: WORKSHOP_MCP_PATH env, then a sibling
        // `workshop-mcp` next to this executable; missing = fail loudly.
        let bridgePath = Self.resolveMCPBridge(env: env, ownExecutable: ownExecutable)
        if bridgePath == nil, adaptersMode != "fake" {
            Self.log("workshop-mcp not found: set WORKSHOP_MCP_PATH or place "
                     + "workshop-mcp next to the daemon executable")
        }

        func expandHome(_ path: String?) -> String? {
            guard let path else { return nil }
            if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
            return path
        }

        let paths = ProfileBuilder.Paths(
            home: home,
            devinBinary: expandHome(engineersConfig.engineer(.devin)?.executable)
                ?? NSHomeDirectory() + "/.local/bin/devin",
            kimiBinary: expandHome(engineersConfig.engineer(.kimi)?.executable)
                ?? NSHomeDirectory() + "/.kimi-code/bin/kimi",
            mcpBridge: bridgePath ?? "<missing workshop-mcp>",
            runtimeDir: runtime)

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
                    let model = engineersConfig.engineer(.devin)?.model_selection
                        ?? "fusion-claude-fable-5-1-medium-sidekick-swe-2-medium"
                    let (spec, _) = try ProfileBuilder.devinSpec(
                        paths: paths, worktree: worktreeHint, model: model)
                    return ACPHarnessAdapter(spec: spec)
                case .kimi:
                    let spec = try ProfileBuilder.kimiSpec(paths: paths,
                                                           worktree: worktreeHint)
                    return ACPHarnessAdapter(spec: spec)
                case .deepseek:
                    return DeepSeekAdapter(
                        sessionsDir: home + "/sessions/deepseek",
                        model: engineersConfig.engineer(.deepseek)?.model_selection
                            ?? DeepSeekAdapter.defaultModel,
                        keyReader: { try DeepSeekAdapter.readCredential() },
                        toolExecutor: { _, _ in "{}" }) // rebound after service init
                }
            } catch {
                Self.log("live adapter \(engineer.rawValue) setup failed: "
                         + error.localizedDescription)
                return nil
            }
        }

        let built: [EngineerAdapter] = EngineerID.allCases.map {
            isFake($0) ? FakeAdapter(engineer: $0) as EngineerAdapter
                : (liveAdapter($0, worktreeHint: home + "/worktrees/_default")
                    ?? UnconfiguredAdapter(engineer: $0))
        }
        self.adapters = built
        let fakeNames = EngineerID.allCases.filter { isFake($0) }.map(\.rawValue)
        if !fakeNames.isEmpty {
            Self.log("WARNING: fake adapters active for [\(fakeNames.joined(separator: ", "))] "
                + "(WORKSHOP_ADAPTERS=\(adaptersMode)); their turns are marked '[FAKE ADAPTER]' in the journal")
        }
        self.adaptersModeLive = Set(EngineerID.allCases.filter { !isFake($0) })

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
        Self.log("opened database at \(dbPath)")
        service.deepLinkHandlerVerified = Self.deepLinkRegistered()
        self.buildID = Self.buildID(executable: ownExecutable)

        // Register the resolved DeepSeek key with the Redactor (compare-only;
        // never logged).
        if let key = try? DeepSeekAdapter.readCredential() {
            Redactor.shared.registerSecret(key)
        }
        self.pendingHome = home

        // DeepSeek executes Workshop tools directly against the service.
        if !isFake(.deepseek) {
            let bound = DeepSeekAdapter(
                sessionsDir: home + "/sessions/deepseek",
                model: engineersConfig.engineer(.deepseek)?.model_selection
                    ?? DeepSeekAdapter.defaultModel,
                keyReader: { try DeepSeekAdapter.readCredential() },
                toolExecutor: { name, args in
                    guard WorkshopToolCatalog.method(for: name) != nil else {
                        return #"{"error":"unknown tool"}"#
                    }
                    do {
                        let result = try await service.callTool(
                            name, args: args, principal: .engineer(.deepseek))
                        let data = try? JSONEncoder().encode(result)
                        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    } catch let error as WorkshopRPCError {
                        return #"{"error":"\#(error.message)"}"#
                    }
                })
            // Managed-history compaction summary comes from the latest valid
            // checkpoint — no model call.
            bound.checkpointSummary = { taskID in
                guard let cp = try? await service.loadValidCheckpoint(
                    taskID: taskID, engineerID: .deepseek) else { return nil }
                return cp.content
            }
            // Rebind without blocking init; the caller awaits readiness.
            self.deepseekRebind = bound
        }

        let server = try IPCServer(socketPath: socket)
        self.server = server
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
                                                              limit: limit))
            case WorkshopProtocol.postMessage:
                let id = TaskID(params?["task_id"]?.stringValue ?? "")
                let body = params?["body"]?.stringValue ?? ""
                return try .from(try await service.postMessage(taskID: id, body: body,
                                                               principal: principal))
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
                    id, beforeSeq: beforeSeq, limit: limit))
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
    }

    /// DeepSeek adapter needing a bound service reference, applied in `start()`.
    private var deepseekRebind: DeepSeekAdapter?

    /// Build identity reported by workshop.health — the bundle's
    /// CFBundleVersion when running packaged ("bundle:<ver>"), else the
    /// executable's mtime+size ("bin:<mtime>-<size>"). The app compares its own
    /// value and only warns when both sides carry a bundle version.
    private var buildID: String?

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

    /// <home>/bin/workshop-mcp → sibling of this executable.
    static func installBridgeSymlink(home: String, ownExecutable: String) {
        let fm = FileManager.default
        let target = (ownExecutable as NSString).deletingLastPathComponent
            + "/workshop-mcp"
        guard fm.fileExists(atPath: target) else { return }
        let binDir = home + "/bin"
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let link = binDir + "/workshop-mcp"
        if (try? fm.destinationOfSymbolicLink(atPath: link)) == target { return }
        try? fm.removeItem(atPath: link)
        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            Self.log("bridge symlink \(link) -> \(target)")
        } catch {
            Self.log("bridge symlink failed: \(error.localizedDescription)")
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

    /// Listen on the socket, bind the DeepSeek adapter, broadcast events, and
    /// start service recovery/dispatch.
    private var pendingHome: String?
    private var adaptersModeLive: Set<EngineerID> = []

    public func start() async throws {
        if let bound = deepseekRebind {
            await service.registerAdapter(bound)
            deepseekRebind = nil
        }
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
        if adaptersModeLive.contains(.deepseek) {
            await service.refreshDeepSeekBalance()
        }
        try server.start()
        Self.log("listening on \(socketPath)")
        broadcastTask = Task.detached { [service, server] in
            for await event in await service.makeEventStream() {
                server.broadcastEvent(event)
            }
        }
        await service.start()
    }

    public func shutdown() async {
        broadcastTask?.cancel()
        await service.shutdown()
        server.stop()
    }
}
