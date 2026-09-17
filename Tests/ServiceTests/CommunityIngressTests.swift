import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

final class CommunityIngressTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-ingress-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func fakes(health: EngineerHealth = .available("ok")) -> [FakeAdapter] {
        EngineerID.allCases.map { FakeAdapter(engineer: $0, delayPerDelta: .zero, health: health) }
    }

    private func service(adapters: [EngineerAdapter], dispatcher: Bool = true,
                         file: String = "db.sqlite",
                         researchDeadline: TimeInterval = 0,
                         reviewDeadline: TimeInterval = 0) throws -> CollaborationService {
        try CollaborationService(databasePath: dir + "/" + file, adapters: adapters,
                                 dispatcherEnabled: dispatcher,
                                 wakeupCoalescence: .zero,
                                 researchDeadline: researchDeadline,
                                 reviewDeadline: reviewDeadline)
    }

    private func v2Request(key: String = "v2-1",
                           mode: CollaborationMode? = nil,
                           participants: [EngineerID] = [],
                           phase: TaskPhase = .execution,
                           origin: TaskOrigin? = nil) -> CreateTaskRequest {
        CreateTaskRequest(schemaVersion: 2, idempotencyKey: key, title: "T",
                          objective: "obj", phase: phase, participants: participants,
                          collaborationMode: mode, origin: origin)
    }

    private func codexOrigin(_ invocation: String = "invocation-a") -> TaskOrigin {
        TaskOrigin(sourceTaskID: "test-codex-thread", invocationID: invocation)
    }

    func testV2OwnerOnlyEmptyParticipantsDispatchesDevinOnly() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(v2Request(mode: .ownerOnly))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.participants.map(\.engineerID), [.devin])
        XCTAssertEqual(adapters[0].turnCount, 1)
        XCTAssertEqual(adapters[1].turnCount, 0)
        XCTAssertEqual(adapters[2].turnCount, 0)
        await svc.shutdown()
    }

    func testV2OmittedModeDefaultsOwnerOnly() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(v2Request(mode: nil, participants: []))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.participants.map(\.engineerID), [.devin])
        XCTAssertEqual(detail.ingress?.request.schemaVersion, 2)
        XCTAssertNil(detail.ingress?.request.collaborationMode)
        XCTAssertEqual(adapters[0].turnCount, 1)
        XCTAssertEqual(adapters[1].turnCount, 0)
        XCTAssertEqual(adapters[2].turnCount, 0)
        await svc.shutdown()
    }

    func testV2OwnerOnlyResearchWakesOnlyDevin() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(
            v2Request(mode: .ownerOnly, phase: .researchProposal))
        await svc.start()
        await svc.awaitIdle()
        XCTAssertEqual(adapters[0].turnCount, 1)
        XCTAssertEqual(adapters[0].receivedContexts.first?.wakeReason, "research_proposal")
        XCTAssertEqual(adapters[1].turnCount, 0)
        XCTAssertEqual(adapters[2].turnCount, 0)
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .researching)
        await svc.shutdown()
    }

    func testV2RequestedPeersExecutionWakesKimiOnce() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(
            v2Request(mode: .requestedPeers, participants: [.kimi]))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(Set(detail.participants.map(\.engineerID)), Set([.devin, .kimi]))
        XCTAssertEqual(adapters[0].turnCount, 1)
        XCTAssertEqual(adapters[1].turnCount, 1)
        XCTAssertEqual(adapters[2].turnCount, 0)
        let kimiContext = try XCTUnwrap(adapters[1].receivedContexts.first)
        XCTAssertEqual(kimiContext.wakeReason, "collaboration_requested")
        let packet = kimiContext.packetText(for: .kimi)
        XCTAssertTrue(packet.contains("explicitly requested your collaboration"))
        await svc.shutdown()
    }

    func testV2IngressCarriesFullBriefMetadata() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        var request = v2Request(mode: .requestedPeers, participants: [.kimi])
        request.constraints = ["Native macOS", "No new deps"]
        request.sources = ["docs/spec.md", "adr/0001.md"]
        request.workspaceRef = "registered-project-id"
        _ = try await svc.createTask(request)
        await svc.start()
        await svc.awaitIdle()
        let kimiContext = try XCTUnwrap(adapters[1].receivedContexts.first)
        let ingress = try XCTUnwrap(kimiContext.ingress)
        XCTAssertEqual(ingress.request.constraints, ["Native macOS", "No new deps"])
        XCTAssertEqual(ingress.request.sources, ["docs/spec.md", "adr/0001.md"])
        XCTAssertEqual(ingress.request.workspaceRef, "registered-project-id")
        let packet = kimiContext.packetText(for: .kimi)
        XCTAssertTrue(packet.contains("Delivery owner: Devin Fusion. Collaboration mode: requested_peers."))
        XCTAssertTrue(packet.contains("Constraints: Native macOS; No new deps"))
        XCTAssertTrue(packet.contains("Sources: docs/spec.md; adr/0001.md"))
        XCTAssertTrue(packet.contains("Requested workspace reference: registered-project-id"))
        await svc.shutdown()
    }

    private func expectInvalid(_ request: CreateTaskRequest,
                               principal: Principal = .user,
                               file: String = "db.sqlite") async throws {
        let svc = try service(adapters: fakes(), dispatcher: false, file: file)
        do {
            _ = try await svc.createTask(request, principal: principal)
            XCTFail("expected invalidRequest")
        } catch WorkshopError.invalidRequest {
        }
        let tasks = try await svc.listTasks()
        XCTAssertEqual(tasks.count, 0)
        await svc.shutdown()
    }

    func testV2ValidationRejectionsInsertNothing() async throws {
        try await expectInvalid(v2Request(key: "bad-owner",
                                          mode: .ownerOnly, participants: [.kimi]))
        try await expectInvalid(v2Request(key: "bad-empty", mode: .requestedPeers,
                                          participants: []))
        try await expectInvalid(v2Request(key: "bad-devin", mode: .requestedPeers,
                                          participants: [.devin]))
        var badSchema = v2Request(key: "bad-schema")
        badSchema.schemaVersion = 3
        try await expectInvalid(badSchema)
        try await expectInvalid(v2Request(key: "   "))
        try await expectInvalid(v2Request(key: "bad-follow", phase: .followUp))
        var v1Mode = CreateTaskRequest(idempotencyKey: "v1-mode", title: "T",
                                       objective: "o", phase: .execution,
                                       participants: [.devin])
        v1Mode.collaborationMode = .ownerOnly
        try await expectInvalid(v1Mode)
        var v1Origin = CreateTaskRequest(idempotencyKey: "v1-origin", title: "T",
                                         objective: "o", phase: .execution,
                                         participants: [.devin])
        v1Origin.origin = codexOrigin()
        try await expectInvalid(v1Origin)
        try await expectInvalid(
            v2Request(key: "codex-invocation-invocation-a",
                      origin: codexOrigin()), principal: .user)
        try await expectInvalid(
            v2Request(key: "codex-invocation-other",
                      origin: codexOrigin()), principal: .codex)
        try await expectInvalid(
            v2Request(key: "codex-invocation-",
                      origin: TaskOrigin(sourceTaskID: " ", invocationID: "")),
            principal: .codex)
    }

    func testV2DuplicateRequestedPeersCanonicalize() async throws {
        let adapters = fakes()
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(
            v2Request(mode: .requestedPeers, participants: [.kimi, .kimi]))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(Set(detail.participants.map(\.engineerID)), Set([.devin, .kimi]))
        XCTAssertEqual(detail.ingress?.request.participants, [.kimi, .kimi])
        await svc.shutdown()
    }

    func testV2CodexOriginIdempotencyAndLookup() async throws {
        let path = "codex.sqlite"
        var receiptA: CreateTaskReceipt!
        var receiptB: CreateTaskReceipt!
        do {
            let svc = try service(adapters: fakes(), dispatcher: false, file: path)
            let requestA = v2Request(key: "codex-invocation-invocation-a",
                                     origin: codexOrigin("invocation-a"))
            receiptA = try await svc.createTask(requestA, principal: .codex)
            let retry = try await svc.createTask(requestA, principal: .codex)
            XCTAssertEqual(retry, receiptA)
            var tasks = try await svc.listTasks()
            XCTAssertEqual(tasks.count, 1)
            var changed = requestA
            changed.objective = "different"
            do {
                _ = try await svc.createTask(changed, principal: .codex)
                XCTFail("expected idempotencyConflict")
            } catch WorkshopError.idempotencyConflict {
            }
            let requestB = v2Request(key: "codex-invocation-invocation-b",
                                     origin: codexOrigin("invocation-b"))
            receiptB = try await svc.createTask(requestB, principal: .codex)
            XCTAssertNotEqual(receiptA.taskID, receiptB.taskID)
            tasks = try await svc.listTasks()
            XCTAssertEqual(tasks.count, 2)
            await svc.shutdown()
        }
        let svc2 = try service(adapters: fakes(), dispatcher: false, file: path)
        let requestA = v2Request(key: "codex-invocation-invocation-a",
                                 origin: codexOrigin("invocation-a"))
        let replayed = try await svc2.createTask(requestA, principal: .codex)
        XCTAssertEqual(replayed, receiptA)
        let detailA = try await svc2.getTask(receiptA.taskID)
        let ingressA = try XCTUnwrap(detailA.ingress)
        XCTAssertEqual(ingressA.request, requestA)
        XCTAssertEqual(ingressA.source, "codex")
        XCTAssertEqual(ingressA.lastAcknowledgedSeq, 0)
        let detailB = try await svc2.getTask(receiptB.taskID)
        XCTAssertEqual(detailB.ingress?.request.origin?.invocationID, "invocation-b")
        let repo = WorkshopRepository(db: try Database(path: dir + "/" + path))
        XCTAssertEqual(try repo.taskIDForOrigin(
            principal: "codex", sourceTaskID: "test-codex-thread",
            invocationID: "invocation-a"), receiptA.taskID)
        XCTAssertEqual(try repo.taskIDForOrigin(
            principal: "codex", sourceTaskID: "test-codex-thread",
            invocationID: "invocation-b"), receiptB.taskID)
        XCTAssertNil(try repo.taskIDForOrigin(
            principal: "codex", sourceTaskID: "test-codex-thread",
            invocationID: "invocation-none"))
        await svc2.shutdown()
    }

    func testPrincipalKeyCollisionRejected() async throws {
        let svc = try service(adapters: fakes(), dispatcher: false)
        let request = v2Request(key: "shared-key", mode: .ownerOnly)
        _ = try await svc.createTask(request, principal: .codex)
        do {
            _ = try await svc.createTask(request, principal: .user)
            XCTFail("expected idempotencyConflict")
        } catch WorkshopError.idempotencyConflict {
        }
        let tasks = try await svc.listTasks()
        XCTAssertEqual(tasks.count, 1)
        await svc.shutdown()
    }

    func testV2DevinUnavailableBlocksWithoutPeerFallthrough() async throws {
        let adapters = fakes()
        adapters[0].setHealth(.unavailable("devin offline"))
        let svc = try service(adapters: adapters)
        let receipt = try await svc.createTask(
            v2Request(mode: .requestedPeers, participants: [.kimi]))
        await svc.start()
        await svc.awaitIdle()
        let detail = try await svc.getTask(receipt.taskID)
        XCTAssertEqual(detail.task.state, .blocked)
        XCTAssertNil(detail.subtasks.first?.ownerID)
        let messages = try await svc.readMessages(receipt.taskID)
        XCTAssertTrue(messages.contains {
            $0.kind == .systemEvent
                && $0.body == "Delivery owner unavailable; waiting for Fusion "
                    + "or an explicit reassignment"
        })
        XCTAssertEqual(adapters[1].turnCount, 1)
        XCTAssertEqual(adapters[1].receivedContexts.first?.wakeReason,
                       "collaboration_requested")
        XCTAssertEqual(adapters[2].turnCount, 0)
        await svc.shutdown()
    }

    func testLegacyTaskDetailWithoutIngressDecodes() throws {
        let detail = TaskDetail(
            task: WorkshopTask(id: TaskID("task_x"), channel: "projects",
                               title: "T", brief: "b", phase: .execution,
                               state: .queued, createdAt: Date(), updatedAt: Date()),
            participants: [], subtasks: [])
        let data = try JSONEncoder().encode(detail)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data)
                                   as? [String: Any])
        object.removeValue(forKey: "ingress")
        let legacy = try JSONDecoder().decode(
            TaskDetail.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.ingress)
        XCTAssertEqual(legacy.task.id, detail.task.id)
    }

    func testV4UpgradeKeepsLegacyRetry() async throws {
        let path = "upgrade.sqlite"
        do {
            let db = try Database(path: dir + "/" + path)
            try Migrator(migrations: [Migrations.v1, Migrations.v2,
                                      Migrations.v3, Migrations.v4]).migrate(db)
            try db.execute("""
                INSERT INTO tasks(id, channel, title, brief, phase, state,
                                  created_at, updated_at)
                VALUES('task_legacy', 'projects', 'Old', 'old brief',
                       'execution', 'queued', 't0', 't0')
                """)
            let receipt = CreateTaskReceipt(taskID: TaskID("task_legacy"),
                                            committedSeq: 1, state: .queued,
                                            status: .created)
            let receiptJSON = String(
                decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
            let legacyRequest = CreateTaskRequest(
                idempotencyKey: "legacy-key", title: "Old",
                objective: "old brief", phase: .execution, participants: [])
            let hash = try canonicalJSONHash(of: legacyRequest)
            try db.execute("""
                INSERT INTO operations(idempotency_key, principal, payload_hash,
                                       result_json, created_at)
                VALUES('legacy-key', 'user', ?, ?, 't0')
                """, [.text(hash), .text(receiptJSON)])
        }
        let svc = try service(adapters: fakes(), dispatcher: false, file: path)
        let retried = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "legacy-key", title: "Old", objective: "old brief",
            phase: .execution, participants: []))
        XCTAssertEqual(retried.taskID, TaskID("task_legacy"))
        let detail = try await svc.getTask(TaskID("task_legacy"))
        XCTAssertNil(detail.ingress)
        await svc.shutdown()
    }

    func testCorruptIngressBlocksExecutionDispatch() async throws {
        let path = "corrupt.sqlite"
        var taskID: TaskID!
        do {
            let svc = try service(adapters: fakes(), dispatcher: false, file: path)
            taskID = try await svc.createTask(
                v2Request(mode: .requestedPeers, participants: [.kimi])).taskID
            await svc.shutdown()
        }
        do {
            let db = try Database(path: dir + "/" + path)
            try db.execute("UPDATE task_ingress SET request_json=? WHERE task_id=?",
                           [.text("{bad"), .text(taskID.rawValue)])
            let repo = WorkshopRepository(db: db)
            XCTAssertThrowsError(try repo.taskIngress(taskID))
        }
        let adapters = fakes()
        let svc = try service(adapters: adapters, file: path)
        await svc.start()
        await svc.awaitIdle()
        XCTAssertEqual(adapters.map(\.turnCount).reduce(0, +), 0)
        let tasks = try await svc.listTasks()
        XCTAssertEqual(tasks.first?.state, .blocked)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.body == "Task ingress could not be decoded; dispatch blocked" })
        await svc.shutdown()
    }

    func testCorruptIngressBlocksResearchWakeups() async throws {
        let path = "corrupt-research.sqlite"
        var taskID: TaskID!
        do {
            let svc = try service(adapters: fakes(), dispatcher: false, file: path)
            taskID = try await svc.createTask(
                v2Request(mode: .ownerOnly, phase: .researchProposal)).taskID
            await svc.shutdown()
        }
        do {
            let db = try Database(path: dir + "/" + path)
            try db.execute("UPDATE task_ingress SET request_json=? WHERE task_id=?",
                           [.text("{bad"), .text(taskID.rawValue)])
            let repo = WorkshopRepository(db: db)
            XCTAssertThrowsError(try repo.taskIngress(taskID))
        }
        let adapters = fakes()
        let svc = try service(adapters: adapters, file: path)
        await svc.start()
        _ = try await svc.insertWakeupForTest(taskID: taskID, engineer: .devin,
                                              reason: "research_proposal",
                                              state: "pending")
        _ = try await svc.postMessage(taskID: taskID, body: "ping")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await svc.listTasks().first?.state == .blocked { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        await svc.awaitIdle()
        XCTAssertEqual(adapters.map(\.turnCount).reduce(0, +), 0)
        let tasks = try await svc.listTasks()
        XCTAssertEqual(tasks.first?.state, .blocked)
        let messages = try await svc.readMessages(taskID)
        XCTAssertTrue(messages.contains {
            $0.body == "Task ingress could not be decoded; dispatch blocked" })
        await svc.shutdown()
    }

    func testCreateTaskJSONSurfaceV2() async throws {
        let svc = try service(adapters: fakes(), dispatcher: false)
        let defaultMode = try await svc.callTool(
            "workshop_create_task",
            args: .object([
                "schema_version": .number(2),
                "idempotency_key": .string("json-v2-default"),
                "title": .string("T"), "objective": .string("obj"),
                "phase": .string("execution"),
            ]), principal: .user)
        XCTAssertEqual(defaultMode["state"]?.stringValue, "queued")
        XCTAssertEqual(defaultMode["status"]?.stringValue, "queued")
        let defaultID = TaskID(defaultMode["task_id"]!.stringValue!)
        let defaultDetail = try await svc.getTask(defaultID)
        XCTAssertEqual(defaultDetail.participants.map(\.engineerID), [.devin])
        XCTAssertNil(defaultDetail.ingress?.request.collaborationMode)
        let peers = try await svc.callTool(
            "workshop_create_task",
            args: .object([
                "schema_version": .number(2),
                "collaboration_mode": .string("requested_peers"),
                "idempotency_key": .string("json-v2-peers"),
                "title": .string("T"), "objective": .string("obj"),
                "phase": .string("execution"),
                "participants": .array([.string("deepseek")]),
            ]), principal: .user)
        XCTAssertEqual(peers["state"]?.stringValue, "queued")
        XCTAssertEqual(peers["status"]?.stringValue, "queued")
        let peersID = TaskID(peers["task_id"]!.stringValue!)
        let peersDetail = try await svc.getTask(peersID)
        XCTAssertEqual(Set(peersDetail.participants.map(\.engineerID)),
                       Set([.devin, .deepseek]))
        XCTAssertEqual(peersDetail.ingress?.request.collaborationMode, .requestedPeers)
        await svc.shutdown()
    }
}
