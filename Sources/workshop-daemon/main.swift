import Foundation
import Security
import WorkshopAdapters
import WorkshopCore
import WorkshopIPC
import WorkshopService
import WorkshopStore

func log(_ message: String) {
    FileHandle.standardError.write(Data("[workshop-daemon] \(message)\n".utf8))
}

let env = ProcessInfo.processInfo.environment
let home = env["WORKSHOP_HOME"]
    ?? NSHomeDirectory() + "/Library/Application Support/Workshop"
let fm = FileManager.default

for sub in ["db", "profiles", "sessions/deepseek", "worktrees", "artifacts",
            "diagnostics", "config"] {
    try fm.createDirectory(atPath: home + "/" + sub, withIntermediateDirectories: true)
}

// Per-engineer capability tokens (§9.3): 32 random bytes hex, mode 0600.
for engineer in EngineerID.allCases {
    let dir = home + "/profiles/" + engineer.rawValue
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tokenPath = dir + "/token"
    if !fm.fileExists(atPath: tokenPath) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        chmod(tokenPath, 0o600)
    }
}

let runtimeDir = IPCServer.defaultRuntimeDir()
try fm.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)
chmod(runtimeDir, 0o700)
let socketPath = runtimeDir + "/service.sock"
precondition(socketPath.utf8.count < 100, "socket path too long: \(socketPath)")

// Exclusive single-instance lock.
let lockFD = open(runtimeDir + "/service.lock", O_RDWR | O_CREAT, 0o600)
if lockFD >= 0 {
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        print("workshop-daemon already running")
        exit(0)
    }
}

// Adapter registration: WORKSHOP_ADAPTERS=fake (Phase 1 default) | live |
// mixed:<engineer>=fake,... Live mode reads config/engineers.json, created
// from the committed template on first run (paths only — no secrets).
struct EngineerConfig: Codable {
    var id: String
    var adapter_kind: String?
    var qualified_binary_version: String?
    var model_selection: String?
    var executable: String?
}
struct EngineersFile: Codable {
    var schema_version: Int?
    var engineers: [EngineerConfig]?
    var mcp_bridge: String?

    func engineer(_ id: EngineerID) -> EngineerConfig? {
        engineers?.first { $0.id == id.rawValue }
    }
}

func expandHome(_ path: String?) -> String? {
    guard let path else { return nil }
    if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
    return path
}

let adaptersMode = env["WORKSHOP_ADAPTERS"] ?? "fake"
let engineersPath = home + "/config/engineers.json"
if !fm.fileExists(atPath: engineersPath) {
    // The committed template is copied on first run; resolve it relative to
    // this source file (development checkout layout).
    let templatePath = (#filePath as NSString)
        .deletingLastPathComponent + "/../../Configuration/engineers.template.json"
    try? fm.copyItem(atPath: (templatePath as NSString).standardizingPath,
                     toPath: engineersPath)
}
let engineersConfig: EngineersFile = (try? Data(contentsOf: URL(fileURLWithPath: engineersPath)))
    .flatMap { try? JSONDecoder().decode(EngineersFile.self, from: $0) } ?? EngineersFile()

func isFake(_ engineer: EngineerID) -> Bool {
    if adaptersMode == "live" { return false }
    if adaptersMode == "fake" { return true }
    if adaptersMode.hasPrefix("mixed:") {
        // e.g. mixed:kimi=fake,deepseek=fake
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

func liveAdapter(_ engineer: EngineerID, worktreeHint: String) -> EngineerAdapter? {
    let paths = ProfileBuilder.Paths(
        home: home,
        devinBinary: expandHome(engineersConfig.engineer(.devin)?.executable)
            ?? NSHomeDirectory() + "/.local/bin/devin",
        kimiBinary: expandHome(engineersConfig.engineer(.kimi)?.executable)
            ?? NSHomeDirectory() + "/.kimi-code/bin/kimi",
        mcpBridge: expandHome(engineersConfig.mcp_bridge)
            ?? CommandLine.arguments[0]
                .replacingOccurrences(of: "workshop-daemon", with: "workshop-mcp"))
    do {
        switch engineer {
        case .devin:
            let model = engineersConfig.engineer(.devin)?.model_selection
                ?? "fusion-claude-fable-5-1-medium-sidekick-swe-2-medium"
            let (spec, _) = try ProfileBuilder.devinSpec(paths: paths,
                                                         worktree: worktreeHint,
                                                         model: model)
            return ACPHarnessAdapter(spec: spec)
        case .kimi:
            let spec = try ProfileBuilder.kimiSpec(paths: paths, worktree: worktreeHint)
            return ACPHarnessAdapter(spec: spec)
        case .deepseek:
            return DeepSeekAdapter(
                sessionsDir: home + "/sessions/deepseek",
                keyReader: { try DeepSeekAdapter.readCredential() },
                toolExecutor: { _, _ in "{}" }) // rebound to the service below
        }
    } catch {
        log("live adapter \(engineer.rawValue) setup failed: \(error.localizedDescription)")
        return nil
    }
}

let adapters: [EngineerAdapter] = EngineerID.allCases.map {
    isFake($0) ? FakeAdapter(engineer: $0) as EngineerAdapter
        : (liveAdapter($0, worktreeHint: home + "/worktrees/_default")
            ?? UnconfiguredAdapter(engineer: $0))
}

let dbPath = home + "/db/workshop.sqlite"
let service = try CollaborationService(databasePath: dbPath, adapters: adapters,
                                       homeDir: home)
log("opened database at \(dbPath)")

// DeepSeek executes Workshop tools directly against the service (in-process);
// rebind the adapter now that the service exists.
if !isFake(.deepseek) {
    let bound = DeepSeekAdapter(
        sessionsDir: home + "/sessions/deepseek",
        keyReader: { try DeepSeekAdapter.readCredential() },
        toolExecutor: { name, args in
            guard let rpc = WorkshopToolCatalog.method(for: name) else {
                return #"{"error":"unknown tool"}"#
            }
            do {
                let result = try await service.callTool(rpc, args: args,
                                                        principal: .engineer(.deepseek))
                let data = try? JSONEncoder().encode(result)
                return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            } catch let error as WorkshopRPCError {
                return #"{"error":"\#(error.message)"}"#
            }
        })
    await service.registerAdapter(bound)
}

let server = try IPCServer(socketPath: socketPath)
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
        let receipt = try await service.createTask(request)
        return try .from(receipt)
    case WorkshopProtocol.listTasks:
        return try .from(try await service.listTasks())
    case WorkshopProtocol.getTask:
        let id = TaskID(params?["task_id"]?.stringValue ?? "")
        return try .from(try await service.getTask(id))
    case WorkshopProtocol.readMessages:
        let id = TaskID(params?["task_id"]?.stringValue ?? "")
        let afterSeq = params?["after_seq"]?.intValue ?? 0
        let limit = Int(params?["limit"]?.intValue ?? 500)
        return try .from(try await service.readMessages(id, afterSeq: afterSeq, limit: limit))
    case WorkshopProtocol.postMessage:
        let id = TaskID(params?["task_id"]?.stringValue ?? "")
        let body = params?["body"]?.stringValue ?? ""
        return try .from(try await service.postMessage(taskID: id, body: body,
                                                       principal: principal))
    case WorkshopProtocol.listEngineers:
        return try .from(await service.listEngineers())
    default:
        // Collaboration tool methods route through callTool when the method
        // name is one of the workshop_* tools.
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
server.replayEvents = { afterSeq in
    (try? serviceOutbox(afterSeq: afterSeq)) ?? []
}

// Replay helper needs actor access; bridge through a semaphore-free approach.
func serviceOutbox(afterSeq: Int64) throws -> [OutboxEvent] {
    // Called synchronously from a connection thread; use a blocking round-trip.
    var result: [OutboxEvent] = []
    var error: Error?
    let sem = DispatchSemaphore(value: 0)
    Task {
        do { result = try await service.outboxEvents(afterSeq: afterSeq) }
        catch let e { error = e }
        sem.signal()
    }
    sem.wait()
    if let error { throw error }
    return result
}

try server.start()
log("listening on \(socketPath)")

// Forward committed service events to subscribed connections.
Task.detached {
    for await event in await service.makeEventStream() {
        server.broadcastEvent(event)
    }
}

Task.detached { await service.start() }

let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM,
                                             queue: DispatchQueue.global())
signal(SIGTERM, SIG_IGN)
sigSrc.setEventHandler {
    log("SIGTERM received, shutting down")
    Task.detached {
        await service.shutdown()
        server.stop()
        exit(0)
    }
}
sigSrc.resume()

// Park the main thread; the accept/reader threads do the work.
while true {
    Thread.sleep(forTimeInterval: 3600)
}
