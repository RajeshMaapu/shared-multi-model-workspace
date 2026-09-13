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

        let dbPath = home + "/db/workshop.sqlite"
        let service = try CollaborationService(databasePath: dbPath,
                                               adapters: built, homeDir: home)
        self.service = service
        Self.log("opened database at \(dbPath)")

        // DeepSeek executes Workshop tools directly against the service.
        if !isFake(.deepseek) {
            let bound = DeepSeekAdapter(
                sessionsDir: home + "/sessions/deepseek",
                keyReader: { try DeepSeekAdapter.readCredential() },
                toolExecutor: { name, args in
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
                    do {
                        let result = try await service.callTool(
                            name, args: args, principal: .engineer(.deepseek))
                        let data = try? JSONEncoder().encode(result)
                        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    } catch let error as WorkshopRPCError {
                        return #"{"error":"\#(error.message)"}"#
                    }
                })
            // Rebind without blocking init; the caller awaits readiness.
            self.deepseekRebind = bound
        }

        let server = try IPCServer(socketPath: socket)
        self.server = server
        server.authenticator = { token in try await service.authenticate(token: token) }
        server.handler = { method, params, principal in
            switch method {
            case WorkshopProtocol.health:
                return .object([
                    "status": .string("ok"),
                    "protocol_version": .number(Double(WorkshopProtocol.version)),
                ])
            case WorkshopProtocol.createTask:
                let request = try (params ?? .object([:])).decode(as: CreateTaskRequest.self)
                return try .from(try await service.createTask(request))
            case WorkshopProtocol.listTasks:
                return try .from(try await service.listTasks())
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
            default:
                if method.hasPrefix("workshop_"),
                   WorkshopToolCatalog.method(for: method) != nil
                    || ["workshop_create_task", "workshop_propose_subtask",
                        "workshop_claim_subtask", "workshop_assign_subtask"].contains(method) {
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
    public func start() async throws {
        if let bound = deepseekRebind {
            await service.registerAdapter(bound)
            deepseekRebind = nil
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
