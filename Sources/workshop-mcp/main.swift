import Foundation
import WorkshopCore
import WorkshopIPC
import WorkshopMCP
import WorkshopService

// workshop-mcp — MCP stdio bridge into the Workshop daemon.
//   workshop-mcp --engineer <id> --token-file <path> [--runtime-dir <dir>]
//   workshop-mcp --principal codex --token-file <path> [--runtime-dir <dir>]
//
// stdout carries ONLY MCP protocol; diagnostics go to stderr. When the daemon
// is unreachable the bridge still starts (so the client sees the tools) but
// every tools/call returns isError "service not running" (T35).

struct ServiceUnavailable: WorkshopRPCError {
    var rpcCode: Int { -32000 }
    var message: String {
        "Workshop service is not running. Open Workshop.app (or start the "
            + "background helper). Nothing was submitted."
    }
}

var principalName = ""
var tokenFile = ""
var runtimeDir: String?
var i = 1
let args = CommandLine.arguments
while i < args.count {
    switch args[i] {
    case "--engineer" where i + 1 < args.count,
         "--principal" where i + 1 < args.count:
        principalName = args[i + 1]; i += 2
    case "--token-file" where i + 1 < args.count:
        tokenFile = args[i + 1]; i += 2
    case "--runtime-dir" where i + 1 < args.count:
        runtimeDir = args[i + 1]; i += 2
    default:
        i += 1
    }
}

guard principalName == "codex" || EngineerID(rawValue: principalName) != nil,
      !tokenFile.isEmpty else {
    FileHandle.standardError.write(Data(
        ("usage: workshop-mcp (--engineer <id>|--principal <id>) "
            + "--token-file <path> [--runtime-dir <dir>]\n").utf8))
    exit(2)
}

guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
    FileHandle.standardError.write(
        Data("workshop-mcp: cannot read token file\n".utf8))
    exit(2)
}

let socketPath = (runtimeDir ?? IPCServer.defaultRuntimeDir()) + "/service.sock"
let lock = NSLock()
func makeOutput() -> (String) -> Void {
    { line in
        lock.lock()
        FileHandle.standardOutput.write(Data(line.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
        lock.unlock()
    }
}

// The closures must be nonisolated: top-level code here is @MainActor, and a
// main-actor async toolCaller would deadlock — awaiting it hops to the main
// thread, which is blocked in runStdio.
// Connect for each call so startup-before-daemon and daemon restarts recover.
// Never replay a request after dispatch: a dropped response can be ambiguous.
func makeToolCaller(socketPath: String, token: String)
    -> (String, JSONValue) async throws -> JSONValue {
    { method, args in
        let client = WorkshopClient(socketPath: socketPath)
        do { try await client.connect() }
        catch { throw ServiceUnavailable() }
        do {
            _ = try await client.call(WorkshopProtocol.authenticate,
                                     params: .object(["token": .string(token)]))
            let result = try await client.call(method, params: args)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

let bridge = MCPBridge(engineer: .devin,
    toolCaller: makeToolCaller(socketPath: socketPath, token: token),
    output: makeOutput())
bridge.runStdio()
