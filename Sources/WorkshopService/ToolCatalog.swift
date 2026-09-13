import Foundation
import WorkshopCore

/// Schema catalog for the Workshop collaboration tools (§8.3). Shared by the
/// MCP bridge (tools/list) and the DeepSeek adapter (tools param).
public enum WorkshopToolCatalog {
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    private static func obj(_ props: [String: JSONValue],
                            required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(props),
                 "required": .array(required.map { .string($0) })])
    }

    private static var s: JSONValue { .object(["type": .string("string")]) }
    private static var i: JSONValue { .object(["type": .string("integer")]) }

    public static let tools: [Tool] = [
        Tool(name: "workshop_get_task",
             description: "Get the task detail: title, brief, acceptance criteria, state, participants, artifacts, latest usage.",
             inputSchema: obj(["task_id": s], required: ["task_id"])),
        Tool(name: "workshop_read_messages",
             description: "Read committed messages in a task after a seq.",
             inputSchema: obj(["task_id": s, "after_seq": i, "limit": i],
                              required: ["task_id"])),
        Tool(name: "workshop_post_message",
             description: "Post a message to a task. Mention @devin/@kimi/@deepseek to wake a peer.",
             inputSchema: obj(["task_id": s, "body": s, "kind": s],
                              required: ["task_id", "body"])),
        Tool(name: "workshop_request_review",
             description: "Ask a participant engineer to review work on a task.",
             inputSchema: obj(["task_id": s, "reviewer": s, "message": s],
                              required: ["task_id", "reviewer", "message"])),
        Tool(name: "workshop_publish_artifact",
             description: "Publish a file from the task workspace as a content-addressed artifact.",
             inputSchema: obj(["task_id": s, "path": s, "description": s],
                              required: ["task_id", "path", "description"])),
        Tool(name: "workshop_report_result",
             description: "Owner only: report a subtask result with artifacts and validation.",
             inputSchema: obj(["task_id": s, "subtask_id": s, "summary": s,
                               "artifact_ids": .object(["type": .string("array"),
                                                        "items": s]),
                               "validation": .object(["type": .string("array"),
                                                      "items": .object(["type": .string("object")])])],
                              required: ["task_id", "subtask_id", "summary"])),
        Tool(name: "workshop_get_capacity",
             description: "Per-engineer capacity buckets. Values are 'unknown' until measured.",
             inputSchema: obj([:])),
        Tool(name: "workshop_save_checkpoint",
             description: "Persist a resumable checkpoint payload for your session binding.",
             inputSchema: obj(["task_id": s, "schema_version": i, "content": s],
                              required: ["task_id", "schema_version", "content"])),
        Tool(name: "workshop_submit_proposal",
             description: "Research phase: submit your independent proposal (stored as a private draft until published).",
             inputSchema: obj(["task_id": s, "title": s, "summary": s, "approach": s,
                               "alternatives": .object(["type": .string("array"),
                                                        "items": .object(["type": .string("object")])]),
                               "tradeoffs": s, "sources": .object(["type": .string("array"), "items": s]),
                               "risks": s,
                               "proposed_ownership": .object(["type": .string("array"),
                                                              "items": .object(["type": .string("object")])]),
                               "acceptance_tests": .object(["type": .string("array"), "items": s]),
                               "estimated_cost": s],
                              required: ["task_id", "title", "summary", "approach"])),
        Tool(name: "workshop_read_proposals",
             description: "Read published proposals (and your own draft) for a research task.",
             inputSchema: obj(["task_id": s], required: ["task_id"])),
        Tool(name: "workshop_submit_review",
             description: "Submit a review of a published proposal or a result message.",
             inputSchema: obj(["task_id": s, "proposal_id": s, "severity": s,
                               "disposition": s, "body": s, "evidence": s],
                              required: ["task_id", "proposal_id", "severity",
                                         "disposition", "body"])),
        Tool(name: "workshop_submit_report",
             description: "Devin only: submit the consolidated report (new revision).",
             inputSchema: obj(["task_id": s, "recommendation": s,
                               "alternatives": .object(["type": .string("array"),
                                                        "items": .object(["type": .string("object")])]),
                               "tradeoffs": s, "sources": .object(["type": .string("array"), "items": s]),
                               "disagreements": .object(["type": .string("array"),
                                                         "items": .object(["type": .string("object")])]),
                               "proposed_ownership": .object(["type": .string("array"),
                                                              "items": .object(["type": .string("object")])]),
                               "risks": s,
                               "acceptance_tests": .object(["type": .string("array"), "items": s])],
                              required: ["task_id", "recommendation"])),
        Tool(name: "workshop_assign_subtask",
             description: "Devin (arbiter) or user: assign a ready subtask to an owner.",
             inputSchema: obj(["task_id": s, "subtask_id": s, "owner": s,
                               "rationale": s, "expected_generation": i],
                              required: ["task_id", "subtask_id", "owner"])),
        Tool(name: "workshop_claim_subtask",
             description: "Claim an unowned, unblocked subtask on an approved task.",
             inputSchema: obj(["task_id": s, "subtask_id": s],
                              required: ["task_id", "subtask_id"])),
        Tool(name: "workshop_propose_subtask",
             description: "Propose a new subtask on an approved task.",
             inputSchema: obj(["task_id": s, "title": s,
                               "acceptance_criteria": .object(["type": .string("array"), "items": s]),
                               "proposed_owner": s, "risk": s,
                               "depends_on": .object(["type": .string("array"), "items": s])],
                              required: ["task_id", "title"])),
        Tool(name: "workshop_dispute_assignment",
             description: "Dispute a subtask assignment; wakes the allocation arbiter.",
             inputSchema: obj(["task_id": s, "subtask_id": s, "body": s],
                              required: ["task_id", "subtask_id", "body"])),
        Tool(name: "workshop_escalate_task",
             description: "Escalate a task to the user: pauses work and asks for a decision.",
             inputSchema: obj(["task_id": s, "reason": s],
                              required: ["task_id", "reason"])),
    ]

    /// The JSON-RPC method name used over IPC is the tool name itself; this
    /// validates membership in the §8.3 catalog.
    public static func method(for tool: String) -> String? {
        tools.contains { $0.name == tool } ? tool : nil
    }
}
