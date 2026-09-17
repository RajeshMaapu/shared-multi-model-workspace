import Foundation
import CryptoKit
import WorkshopCore
import WorkshopService

public struct ACPPermissionDecision: Sendable, Equatable {
    public var tool: String
    public var operation: String
    public var allowed: Bool
    public var reason: String
    public var callID: String?
    public var title: String {
        "Permission " + (allowed ? "allowed" : "denied") + " · " + operation + " · " + reason
    }
}

public struct ACPCommandApproval: Sendable, Equatable {
    public let command: String
    public let cwd: String
    public let absoluteCwd: Bool
    public init(command: String, cwd: String) {
        self.command = command
        self.cwd = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
        self.absoluteCwd = cwd.hasPrefix("/")
    }
}

public struct ACPPermissionPolicy: Sendable {
    public let workspace: String?
    public let approvedCommands: [ACPCommandApproval]
    public init(workspace: String? = nil, approvedCommands: [ACPCommandApproval] = []) {
        self.workspace = workspace.flatMap {
            $0.hasPrefix("/")
                ? URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                : nil
        }
        self.approvedCommands = approvedCommands
    }
    static func identity(_ toolCall: JSONValue) -> (name: String, conflict: Bool) {
        let legacy = toolCall["_meta"]?["cognition.ai/toolName"]?.stringValue
        let native = toolCall["_meta"]?["cognition.ai/inferenceToolName"]?.stringValue
        return (legacy ?? native ?? "", legacy != nil && native != nil && legacy != native)
    }

    public func decide(toolCall: JSONValue) -> ACPPermissionDecision {
        let identity = Self.identity(toolCall)
        let rawName = identity.name
        let kind = toolCall["kind"]?.stringValue ?? ""
        let callID = toolCall["toolCallId"]?.stringValue.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let names = Set(WorkshopToolCatalog.tools.map { "mcp__workshop__" + $0.name })
        let reads: Set<String> = ["read", "grep", "find_file_by_name", "list_dir"]
        let commandTool = rawName == "exec" || rawName == "shell"
        let operation = commandTool ? "execute" : reads.contains(rawName) ? "read" : names.contains(rawName) ? "workshop" : "unknown"
        let normalized = operation == "unknown" ? "unknown" : rawName
        func result(_ allowed: Bool, _ reason: String) -> ACPPermissionDecision {
            ACPPermissionDecision(tool: normalized, operation: operation, allowed: allowed, reason: reason, callID: callID)
        }
        if identity.conflict { return result(false, "unknown_or_conflicting_identity") }
        if names.contains(rawName) {
            guard !["execute", "delete", "move", "fetch", "think"].contains(kind),
                  ["", "other", "read", "search", "edit"].contains(kind) else {
                return result(false, "unknown_or_conflicting_identity")
            }
            return result(true, "known_workshop_tool")
        }
        if reads.contains(rawName) && (kind.isEmpty || kind == "read" || kind == "search") {
            return result(true, "typed_read_tool")
        }
        guard commandTool, kind.isEmpty || kind == "execute" else { return result(false, "unknown_or_conflicting_identity") }
        guard case .object(let input)? = toolCall["rawInput"],
              Set(input.keys).isSubset(of: ["command", "workdir", "timeout"]),
              let command = input["command"]?.stringValue,
              command.utf8.count <= 16384,
              let workspace else { return result(false, "missing_scoped_command") }
        let cwd: String
        if let value = input["workdir"] {
            guard let path = value.stringValue, path.hasPrefix("/") else { return result(false, "invalid_workdir") }
            cwd = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        } else { cwd = workspace }
        guard cwd == workspace,
              approvedCommands.contains(where: {
                  $0.command == command && $0.cwd == cwd && $0.absoluteCwd }) else {
            return result(false, "command_not_explicitly_approved")
        }
        return result(true, "exact_command_approval")
    }
}
