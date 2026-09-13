import Foundation
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

for sub in ["db", "profiles", "sessions", "worktrees", "artifacts", "diagnostics"] {
    try fm.createDirectory(atPath: home + "/" + sub, withIntermediateDirectories: true)
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

let useFake = (env["WORKSHOP_ADAPTERS"] ?? "fake") == "fake"
// Real adapters land in Phase 2; without `fake`, engineers probe as unavailable.
let adapters: [EngineerAdapter] = EngineerID.allCases.map {
    useFake ? FakeAdapter(engineer: $0) as EngineerAdapter : UnconfiguredAdapter(engineer: $0)
}

let dbPath = home + "/db/workshop.sqlite"
let service = try CollaborationService(databasePath: dbPath, adapters: adapters)
log("opened database at \(dbPath)")

let server = try IPCServer(socketPath: socketPath)
server.handler = { method, params in
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
        return try .from(try await service.postMessage(taskID: id, body: body))
    case WorkshopProtocol.listEngineers:
        return try .from(await service.listEngineers())
    default:
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
