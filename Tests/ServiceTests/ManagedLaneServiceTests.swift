import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// D-b lane provenance: managed-lane messages carry `lane` in structured,
/// packets tag the author, and getTask reports the recorded lane.
final class ManagedLaneServiceTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-lane-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes() -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero) }
    }

    private func makeService(adapters: [FakeAdapter], dbPath: String)
        throws -> CollaborationService {
        let svc = try CollaborationService(
            databasePath: dbPath, adapters: adapters, dispatcherEnabled: false,
            homeDir: dir, wakeupCoalescence: .zero,
            wakeupRetryBackoff: [.milliseconds(50), .milliseconds(50),
                                 .milliseconds(50)],
            researchDeadline: 0, reviewDeadline: 0)
        for adapter in adapters {
            adapter.toolRunner = { [weak svc] name, args, principal in
                guard let svc else { return .null }
                return try await svc.callTool(name, args: args, principal: principal)
            }
        }
        return svc
    }

    func testManagedLaneProvenance() async throws {
        let adapters = fakes()
        let svc = try makeService(adapters: adapters, dbPath: dir + "/lane.sqlite")
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: UUID().uuidString, title: "T", objective: "obj",
            phase: .execution, participants: [.devin, .kimi]))
        let taskID = receipt.taskID

        // Record the managed lane for kimi, then post as kimi.
        await svc.recordLane(taskID: taskID, engineer: .kimi, lane: "managed")
        let message = try await svc.toolPostMessage(
            taskID: taskID, body: "replying from the managed lane",
            kind: "text", replyTo: nil, principal: .engineer(.kimi))
        let structured = try XCTUnwrap(message.structured)
        let fields = try JSONDecoder().decode(JSONValue.self,
                                              from: Data(structured.utf8))
        XCTAssertEqual(fields["lane"]?.stringValue, "managed")

        // A peer's packet tags the author with (managed lane).
        var packets: [String] = []
        await svc.setPacketInspector { engineer, packet in
            if engineer == .devin { packets.append(packet) }
        }
        await svc.runTurnForTest(engineer: .devin, taskID: taskID,
                               wakeReason: "mention")
        let packet = try XCTUnwrap(packets.last)
        XCTAssertTrue(packet.contains("Kimi K3 (managed lane):"), packet)

        // getTask reports the last recorded lane per participant.
        let detail = try await svc.getTask(taskID)
        XCTAssertEqual(detail.participants.first { $0.engineerID == .kimi }?.lane,
                       "managed")
        XCTAssertNil(detail.participants.first { $0.engineerID == .devin }?.lane)

        // A native-lane message keeps old structured content unchanged.
        await svc.recordLane(taskID: taskID, engineer: .devin, lane: "native")
        let plain = try await svc.toolPostMessage(
            taskID: taskID, body: "plain", kind: "text", replyTo: nil,
            principal: .engineer(.devin))
        XCTAssertNil(plain.structured)
    }
}
