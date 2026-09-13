import XCTest
@testable import WorkshopService
@testable import WorkshopStore
@testable import WorkshopCore

/// §10.3 latency bench — deterministic, fake adapters, real temp SQLite with
/// synchronous=FULL (the shipped setting). Measures p50/p95 over 200
/// iterations and writes docs/evidence/phase4/latency.json when
/// WORKSHOP_EVIDENCE_DIR is set. Numbers are machine-specific, not guarantees.
final class LatencyBench: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "workshop-bench-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        let s = samples.sorted()
        return s[min(Int(Double(s.count) * p), s.count - 1)]
    }

    func testLatencyBench() async throws {
        let iterations = 200
        var createMs: [Double] = []
        var eventMs: [Double] = []
        var wakeupMs: [Double] = []

        let svc = try CollaborationService(
            databasePath: dir + "/bench.sqlite",
            adapters: EngineerID.allCases.map {
                FakeAdapter(engineer: $0, delayPerDelta: .zero) },
            dispatcherEnabled: false, homeDir: dir,
            wakeupCoalescence: .zero, researchDeadline: 0, reviewDeadline: 0)
        let stream = await svc.makeEventStream()
        var iter = stream.makeAsyncIterator()

        for i in 0..<iterations {
            var t0 = Date()
            let receipt = try await svc.createTask(CreateTaskRequest(
                idempotencyKey: "bench-\(i)", title: "Bench \(i)",
                objective: "measure", phase: .execution, participants: [.devin]))
            createMs.append(Date().timeIntervalSince(t0) * 1000)

            // Committed event visible to an in-process subscriber.
            t0 = Date()
            _ = try await svc.postMessage(taskID: receipt.taskID, body: "m\(i)",
                                          principal: .user)
            // Drain until the message.committed event arrives.
            while let event = await iter.next() {
                if event.eventType == "message.committed" { break }
            }
            eventMs.append(Date().timeIntervalSince(t0) * 1000)

            // Wakeup queued.
            t0 = Date()
            _ = try await svc.insertWakeupForTest(taskID: receipt.taskID,
                                                  engineer: .devin,
                                                  reason: "bench",
                                                  state: "pending")
            wakeupMs.append(Date().timeIntervalSince(t0) * 1000)
        }

        // Open a task with 5,000 messages → newest page.
        let receipt = try await svc.createTask(CreateTaskRequest(
            idempotencyKey: "bench-big", title: "Big", objective: "o",
            phase: .execution, participants: [.devin]))
        try await svc.insertMessagesForTest(taskID: receipt.taskID, count: 5_000)
        var openMs: [Double] = []
        for _ in 0..<iterations {
            let t0 = Date()
            let page = try await svc.readMessagePage(receipt.taskID)
            openMs.append(Date().timeIntervalSince(t0) * 1000)
            XCTAssertEqual(page.count, 500)
        }

        let results: [String: [String: Double]] = [
            "create_task_receipt": ["p50": percentile(createMs, 0.50),
                                   "p95": percentile(createMs, 0.95)],
            "committed_event_visible": ["p50": percentile(eventMs, 0.50),
                                        "p95": percentile(eventMs, 0.95)],
            "wakeup_queued": ["p50": percentile(wakeupMs, 0.50),
                              "p95": percentile(wakeupMs, 0.95)],
            "open_task_5000msg_newest_page": ["p50": percentile(openMs, 0.50),
                                              "p95": percentile(openMs, 0.95)],
        ]
        for (name, r) in results.sorted(by: { $0.key < $1.key }) {
            NSLog("LatencyBench %@ p50=%.2fms p95=%.2fms",
                  name, r["p50"] ?? 0, r["p95"] ?? 0)
        }
        if let outDir = ProcessInfo.processInfo
            .environment["WORKSHOP_EVIDENCE_DIR"] {
            try? FileManager.default.createDirectory(
                atPath: outDir, withIntermediateDirectories: true)
            let sync = ProcessInfo.processInfo
                .environment["WORKSHOP_BENCH_SYNC_NORMAL"] == "1"
                ? "NORMAL" : "FULL"
            let payload: JSONValue = .object([
                "iterations": .number(Double(iterations)),
                "synchronous": .string(sync),
                "results_ms": .object(results.mapValues {
                    .object($0.mapValues { .number($0) })
                }),
            ])
            try JSONEncoder().encode(payload)
                .write(to: URL(fileURLWithPath:
                    outDir + "/latency-\(sync.lowercased()).json"))
        }
    }
}
