import Foundation
import WorkshopCore
import WorkshopService

/// MCP stdio bridge: newline-delimited JSON-RPC on stdin/stdout. Protocol
/// version is pinned to "2025-06-18" regardless of what the client offers.
/// tools/call forwards to the daemon via the injected `toolCaller` (the real
/// executable wraps a UDS client + workshop.authenticate; tests inject a
/// direct service call).
public final class MCPBridge: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
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
              msg["jsonrpc"]?.stringValue == "2.0" else { return }
        let id = msg["id"]
        let method = msg["method"]?.stringValue ?? ""
        // Notifications have no id; never answer them.
        guard id != nil else { return }
        switch method {
        case "initialize":
            respond(id, .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("workshop-mcp"),
                    "version": .string("0")]),
            ]))
        case "ping":
            respond(id, .object([:]))
        case "tools/list":
            let list = WorkshopToolCatalog.tools.map { tool in
                JSONValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema])
            }
            respond(id, .object(["tools": .array(list)]))
        case "tools/call":
            guard let name = msg["params"]?["name"]?.stringValue,
                  let rpc = WorkshopToolCatalog.method(for: name) else {
                respondTool(id, text: #"{"error":"unknown tool"}"#, isError: true)
                return
            }
            let args = msg["params"]?["arguments"] ?? .object([:])
            do {
                let result = try await toolCaller(rpc, args)
                let text = String(decoding: (try? JSONEncoder().encode(result)) ?? Data(),
                                  as: UTF8.self)
                respondTool(id, text: text.isEmpty ? "{}" : text, isError: false)
            } catch let error as WorkshopRPCError {
                respondTool(id, text: #"{"error":""#
                    + escape(error.message) + #"","code":\#(error.rpcCode)}"#,
                    isError: true)
            } catch {
                respondTool(id, text: #"{"error":"internal"}"#, isError: true)
            }
        default:
            respondError(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func respondTool(_ id: JSONValue?, text: String, isError: Bool) {
        respond(id, .object([
            "content": .array([.object([
                "type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError)]))
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func respond(_ id: JSONValue?, _ result: JSONValue) {
        let object: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
        if let data = try? JSONEncoder().encode(object) {
            output(String(decoding: data, as: UTF8.self))
        }
    }

    private func respondError(_ id: JSONValue?, code: Int, message: String) {
        let object: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": id ?? .null,
            "error": .object(["code": .number(Double(code)),
                              "message": .string(message)])])
        if let data = try? JSONEncoder().encode(object) {
            output(String(decoding: data, as: UTF8.self))
        }
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
