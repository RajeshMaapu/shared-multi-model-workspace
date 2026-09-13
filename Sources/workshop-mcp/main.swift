import Foundation
import WorkshopCore
import WorkshopIPC
import WorkshopMCP

// workshop-mcp: MCP stdio bridge for one engineer.
// Args: --engineer <id> --token-file <path> [--runtime-dir <dir>]
// Connects to the daemon UDS, authenticates with the capability token, then
// serves MCP on stdin/stdout.

var engineerID = ""
var tokenFile = ""
var runtimeDir: String?
var i = 1
let args = CommandLine.arguments
while i < args.count {
    switch args[i] {
    case "--engineer" where i + 1 < args.count:
        engineerID = args[i + 1]; i += 2
    case "--token-file" where i + 1 < args.count:
        tokenFile = args[i + 1]; i += 2
    case "--runtime-dir" where i + 1 < args.count:
        runtimeDir = args[i + 1]; i += 2
    default:
        i += 1
    }
}

guard let engineer = EngineerID(rawValue: engineerID), !tokenFile.isEmpty else {
    FileHandle.standardError.write(
        Data("usage: workshop-mcp --engineer <id> --token-file <path> [--runtime-dir <dir>]\n".utf8))
    exit(2)
}

guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
    FileHandle.standardError.write(Data("workshop-mcp: cannot read token file\n".utf8))
    exit(2)
}

let socketPath = (runtimeDir ?? IPCServer.defaultRuntimeDir()) + "/service.sock"
let client = WorkshopClient(socketPath: socketPath)
do { try await client.connect() } catch {
    FileHandle.standardError.write(
        Data("workshop-mcp: daemon not reachable at \(socketPath)\n".utf8))
    exit(1)
}
do {
    _ = try await client.call(WorkshopProtocol.authenticate,
                              params: .object(["token": .string(token)]))
} catch {
    FileHandle.standardError.write(Data("workshop-mcp: authenticate failed\n".utf8))
    exit(1)
}

// stdout must carry only protocol; everything else goes to stderr.
// The closures must be nonisolated: top-level code here is @MainActor, and a
// main-actor async toolCaller would deadlock — awaiting it hops to the main
// thread, which is blocked in runStdio.
func makeToolCaller(_ client: WorkshopClient)
    -> (String, JSONValue) async throws -> JSONValue {
    { method, args in try await client.call(method, params: args) }
}
let lock = NSLock()
let bridge = MCPBridge(engineer: engineer, toolCaller: makeToolCaller(client),
                       output: { line in
    lock.lock()
    FileHandle.standardOutput.write(Data(line.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
    lock.unlock()
})
bridge.runStdio()
