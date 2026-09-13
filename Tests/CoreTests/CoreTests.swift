import XCTest
@testable import WorkshopCore

final class CoreTests: XCTestCase {
    func testCreateTaskRequestSnakeCaseRoundTrip() throws {
        // Spec §8.4 example
        let json = """
        {
          "schema_version": 1,
          "idempotency_key": "client-generated-unique-key",
          "title": "Research a caching architecture",
          "objective": "Provide a combined proposal and validation plan",
          "phase": "research_proposal",
          "participants": ["devin", "kimi", "deepseek"],
          "constraints": ["Native macOS", "No implementation before approval"],
          "sources": [],
          "workspace_ref": "registered-project-id",
          "acceptance_criteria": ["Alternatives and disagreements preserved"],
          "budget_policy_ref": "configured-default"
        }
        """
        let request = try JSONDecoder().decode(CreateTaskRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.schemaVersion, 1)
        XCTAssertEqual(request.idempotencyKey, "client-generated-unique-key")
        XCTAssertEqual(request.phase, .researchProposal)
        XCTAssertEqual(request.participants, [.devin, .kimi, .deepseek])
        XCTAssertEqual(request.workspaceRef, "registered-project-id")
        XCTAssertEqual(request.channel, "projects")

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["schema_version", "idempotency_key", "workspace_ref",
                    "acceptance_criteria", "budget_policy_ref", "phase", "participants"] {
            XCTAssertNotNil(object[key], "missing snake_case key \(key)")
        }
        XCTAssertEqual(object["phase"] as? String, "research_proposal")
    }

    func testCanonicalHashStableUnderKeyReordering() throws {
        let a = """
        {"title":"T","objective":"O","idempotency_key":"k","phase":"execution",
         "participants":["devin"],"constraints":[],"sources":[],"acceptance_criteria":[]}
        """
        let b = """
        {"acceptance_criteria":[],"sources":[],"constraints":[],"participants":["devin"],
         "phase":"execution","idempotency_key":"k","objective":"O","title":"T"}
        """
        let ra = try JSONDecoder().decode(CreateTaskRequest.self, from: Data(a.utf8))
        let rb = try JSONDecoder().decode(CreateTaskRequest.self, from: Data(b.utf8))
        XCTAssertEqual(try canonicalJSONHash(of: ra), try canonicalJSONHash(of: rb))

        var rc = ra
        rc.objective = "changed"
        XCTAssertNotEqual(try canonicalJSONHash(of: ra), try canonicalJSONHash(of: rc))
    }

    func testTaskStateTransitions() {
        // Every §8.2 edge.
        let edges: [(TaskState, TaskState)] = [
            (.draft, .queued),
            (.queued, .researching), (.queued, .ready),
            (.researching, .reviewingProposal),
            (.reviewingProposal, .awaitingArchitectureApproval),
            (.awaitingArchitectureApproval, .ready),
            (.ready, .working), (.ready, .cancelled),
            (.working, .verifying), (.working, .blocked),
            (.working, .paused), (.working, .cancelled),
            (.verifying, .done), (.verifying, .working),
            (.blocked, .ready), (.paused, .ready),
        ]
        for (from, to) in edges {
            XCTAssertTrue(from.canTransition(to: to), "\(from) -> \(to) should be allowed")
        }
        XCTAssertFalse(TaskState.done.canTransition(to: .working))
        XCTAssertFalse(TaskState.draft.canTransition(to: .working))
        XCTAssertFalse(TaskState.cancelled.canTransition(to: .ready))
        XCTAssertFalse(TaskState.queued.canTransition(to: .blocked))
    }
}
