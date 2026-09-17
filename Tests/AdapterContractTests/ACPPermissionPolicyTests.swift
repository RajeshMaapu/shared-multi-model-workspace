import XCTest
import Foundation
@testable import WorkshopAdapters
@testable import WorkshopService
@testable import WorkshopCore

final class ACPPermissionPolicyTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-perm-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func toolCall(_ meta: String? = nil, kind: String? = nil,
                          rawInput: JSONValue? = nil, title: String? = nil,
                          id: String = "call-1") -> JSONValue {
        var fields: [String: JSONValue] = ["toolCallId": .string(id)]
        if let meta { fields["_meta"] = .object(["cognition.ai/toolName": .string(meta)]) }
        if let kind { fields["kind"] = .string(kind) }
        if let rawInput { fields["rawInput"] = rawInput }
        if let title { fields["title"] = .string(title) }
        return .object(fields)
    }

    func testExecApprovedExactCommandAndCwdAllowed() {
        let workspace = dir!
        let policy = ACPPermissionPolicy(workspace: workspace, approvedCommands: [
            ACPCommandApproval(command: "/usr/bin/true", cwd: workspace)])
        let call = toolCall("exec", kind: "execute",
                            rawInput: .object(["command": .string("/usr/bin/true")]))
        let decision = policy.decide(toolCall: call)
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.operation, "execute")
        XCTAssertEqual(decision.reason, "exact_command_approval")
        XCTAssertNotNil(decision.callID)
        XCTAssertNotEqual(decision.callID, "call-1")
    }

    func testExecMissingApprovalRejected() {
        let policy = ACPPermissionPolicy(workspace: dir!)
        let call = toolCall("exec", rawInput: .object(["command": .string("/usr/bin/true")]))
        let decision = policy.decide(toolCall: call)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "command_not_explicitly_approved")
    }

    func testExecMangledOrScopedVariantsRejected() {
        let workspace = dir!
        let policy = ACPPermissionPolicy(workspace: workspace, approvedCommands: [
            ACPCommandApproval(command: "/usr/bin/true", cwd: workspace)])
        let appended = policy.decide(toolCall: toolCall("exec",
            rawInput: .object(["command": .string("/usr/bin/true; touch other")])))
        XCTAssertFalse(appended.allowed)
        let parent = policy.decide(toolCall: toolCall("exec",
            rawInput: .object(["command": .string("/usr/bin/true"),
                               "workdir": .string((workspace as NSString).deletingLastPathComponent)])))
        XCTAssertFalse(parent.allowed)
        for extra in ["shell_flavor", "env"] {
            let denied = policy.decide(toolCall: toolCall("exec",
                rawInput: .object(["command": .string("/usr/bin/true"),
                                   extra: .string("x")])))
            XCTAssertFalse(denied.allowed, extra)
        }
        let relative = policy.decide(toolCall: toolCall("exec",
            rawInput: .object(["command": .string("/usr/bin/true"),
                               "workdir": .string("relative/path")])))
        XCTAssertFalse(relative.allowed)
        XCTAssertEqual(relative.reason, "invalid_workdir")
    }

    func testNativeIdentityAliasAndConflict() {
        let policy = ACPPermissionPolicy()
        XCTAssertTrue(policy.decide(toolCall: .object([
            "_meta": .object(["cognition.ai/inferenceToolName": .string("read")]),
            "kind": .string("read")])).allowed)
        XCTAssertFalse(policy.decide(toolCall: .object([
            "_meta": .object(["cognition.ai/toolName": .string("read"),
                              "cognition.ai/inferenceToolName": .string("exec")]),
            "kind": .string("read")])).allowed)
    }

    func testWorkshopToolIdentityRules() {
        let policy = ACPPermissionPolicy()
        XCTAssertTrue(policy.decide(toolCall: toolCall("mcp__workshop__workshop_post_message")).allowed)
        let titleOnly = policy.decide(toolCall: toolCall(nil, title: "Run workshop_post_message"))
        XCTAssertFalse(titleOnly.allowed)
        XCTAssertFalse(policy.decide(toolCall: toolCall("mcp__workshop__made_up")).allowed)
    }

    func testReadTypedToolsAndKindConflicts() {
        let policy = ACPPermissionPolicy()
        XCTAssertTrue(policy.decide(toolCall: toolCall("read", kind: "read")).allowed)
        XCTAssertTrue(policy.decide(toolCall: toolCall("grep", kind: "search")).allowed)
        XCTAssertTrue(policy.decide(toolCall: toolCall("read")).allowed)
        let execRead = policy.decide(toolCall: toolCall("exec", kind: "read",
            rawInput: .object(["command": .string("/usr/bin/true")])))
        XCTAssertFalse(execRead.allowed)
    }

    func testRelativeWorkspaceAndApprovalCwdRejected() {
        let relativePolicy = ACPPermissionPolicy(workspace: "relative/workspace")
        XCTAssertNil(relativePolicy.workspace)
        let call = toolCall("exec", rawInput: .object(["command": .string("/usr/bin/true")]))
        XCTAssertFalse(relativePolicy.decide(toolCall: call).allowed)
        let relativeApproval = ACPPermissionPolicy(workspace: dir!, approvedCommands: [
            ACPCommandApproval(command: "/usr/bin/true", cwd: "relative/cwd")])
        XCTAssertFalse(relativeApproval.decide(toolCall: call).allowed)
    }

    func testWorkshopToolKindConflictsRejected() {
        let policy = ACPPermissionPolicy()
        let name = "mcp__workshop__workshop_post_message"
        for kind in ["execute", "delete", "move", "fetch", "think", "write"] {
            let decision = policy.decide(toolCall: toolCall(name, kind: kind))
            XCTAssertFalse(decision.allowed, kind)
            XCTAssertEqual(decision.reason, "unknown_or_conflicting_identity", kind)
        }
        for kind in ["other", "read", "search", "edit", ""] {
            XCTAssertTrue(policy.decide(toolCall: toolCall(name, kind: kind)).allowed, kind)
        }
    }

    func testOversizedCommandRejected() {
        let workspace = dir!
        let command = "/usr/bin/true " + String(repeating: "a", count: 20 * 1024)
        let policy = ACPPermissionPolicy(workspace: workspace, approvedCommands: [
            ACPCommandApproval(command: command, cwd: workspace)])
        let call = toolCall("exec", rawInput: .object(["command": .string(command)]))
        let decision = policy.decide(toolCall: call)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "missing_scoped_command")
    }

    func testReadToolWithWriteKindRejected() {
        let policy = ACPPermissionPolicy()
        XCTAssertFalse(policy.decide(toolCall: toolCall("read", kind: "write")).allowed)
    }
}
