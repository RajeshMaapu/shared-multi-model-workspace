import Foundation
import WorkshopCore
import WorkshopService

/// Transport-agnostic MCP/JSON-RPC protocol core shared by the stdio bridge
/// (MCPBridge) and the daemon-hosted Streamable HTTP server (MCPHTTPServer).
/// Protocol version negotiates to the client's requested version when it is
/// supported, else falls back to `defaultVersion`.
public enum MCPProtocol {
    public static let supportedVersions: [String] = ["2025-03-26", "2025-06-18",
                                                     "2025-11-25"]
    public static let defaultVersion = "2025-06-18"

    /// Returns the JSON-RPC response object for `msg`, or nil for
    /// notifications (no `id`) and undecodable/non-RPC input.
    public static func respond(to msg: JSONValue,
                               serverVersion: String,
                               toolCaller: (String, JSONValue) async throws -> JSONValue)
        async -> JSONValue? {
        guard msg["jsonrpc"]?.stringValue == "2.0" else { return nil }
        let id = msg["id"]
        let method = msg["method"]?.stringValue ?? ""
        // Notifications have no id; never answer them.
        guard id != nil else { return nil }
        switch method {
        case "initialize":
            let requested = msg["params"]?["protocolVersion"]?.stringValue ?? ""
            let version = supportedVersions.contains(requested)
                ? requested : defaultVersion
            return result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(true)])]),
                "serverInfo": .object([
                    "name": .string("workshop-mcp"),
                    "version": .string(
                        "\(serverVersion)+catalog\(WorkshopToolCatalog.catalogVersion)")]),
            ]))
        case "ping":
            return result(id, .object([:]))
        case "tools/list":
            let list = WorkshopToolCatalog.tools.map { tool in
                JSONValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema])
            }
            return result(id, .object([
                "tools": .array(list),
                "_meta": .object([
                    "workshop_catalog_version":
                        .number(Double(WorkshopToolCatalog.catalogVersion))])]))
        case "tools/call":
            guard let name = msg["params"]?["name"]?.stringValue,
                  let rpc = WorkshopToolCatalog.method(for: name) else {
                return result(id, toolResult(#"{"error":"unknown tool"}"#,
                                             isError: true))
            }
            let args = msg["params"]?["arguments"] ?? .object([:])
            do {
                let callResult = try await toolCaller(rpc, args)
                let text = String(decoding: (try? JSONEncoder().encode(callResult)) ?? Data(),
                                  as: UTF8.self)
                return result(id, toolResult(text.isEmpty ? "{}" : text,
                                             isError: false))
            } catch let error as WorkshopRPCError {
                return result(id, toolResult(#"{"error":""#
                    + escape(error.message) + #"","code":\#(error.rpcCode)}"#,
                    isError: true))
            } catch {
                return result(id, toolResult(#"{"error":"internal"}"#,
                                             isError: true))
            }
        default:
            return .object([
                "jsonrpc": .string("2.0"), "id": id ?? .null,
                "error": .object(["code": .number(-32601),
                                  "message": .string("Method not found: \(method)")])])
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object([
                "type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
            "_meta": .object([
                "workshop_catalog_version":
                    .number(Double(WorkshopToolCatalog.catalogVersion))])])
    }

    private static func result(_ id: JSONValue?, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": value])
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// MCP stdio bridge: newline-delimited JSON-RPC on stdin/stdout — a thin
/// wrapper over `MCPProtocol.respond`. tools/call forwards to the daemon via
/// the injected `toolCaller` (the real executable wraps a UDS client +
/// workshop.authenticate; tests inject a direct service call).
public final class MCPBridge: @unchecked Sendable {
    public static let maxLineBytes = 4 * 1024 * 1024

    private let engineer: EngineerID
    private let toolCaller: (String, JSONValue) async throws -> JSONValue
    private let output: (String) -> Void

    public init(engineer: EngineerID,
                toolCaller: @escaping (String, JSONValue) async throws -> JSONValue,
                output: @escaping (String) -> Void = { print($0) }) {
        self.engineer = engineer
        self.toolCaller = toolCaller
        self.output = output
    }

    /// Process one inbound line; writes any response via `output`.
    public func handle(line: String) async {
        guard line.utf8.count <= Self.maxLineBytes,
              let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let response = await MCPProtocol.respond(to: msg, serverVersion: "0",
                                                       toolCaller: toolCaller),
              let data = try? JSONEncoder().encode(response) else { return }
        output(String(decoding: data, as: UTF8.self))
    }

    /// Run the stdio loop until EOF (used by the executable).
    public func runStdio() {
        let group = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            if line.utf8.count > Self.maxLineBytes { continue }
            group.enter()
            Task {
                await self.handle(line: line)
                group.leave()
            }
        }
        group.wait()
    }
}
