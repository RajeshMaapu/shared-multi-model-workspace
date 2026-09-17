import XCTest
import Foundation
@testable import WorkshopAdapters
@testable import WorkshopService
@testable import WorkshopCore

final class NativeWriterProbeTests: XCTestCase {
    func testFusionRelayCanEditInsideWriterSandbox() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WORKSHOP_NATIVE_WRITER_PROBE"] == "1", "Explicit native writer probe only")
        let root = "/private/tmp/fusion-writer-probe-" + UUID().uuidString
        let work = root + "/writer-runs/probe/workspace"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let executable = NSHomeDirectory() + "/projects/fusion-codex-relay/bin/devin-fusion"
        let paths = ProfileBuilder.Paths(home: root, devinBinary: executable,
            kimiBinary: "/not-used", mcpBridge: "/not-used")
        var spec = try ProfileBuilder.devinSpec(paths: paths, worktree: work,
            model: "fusion-gpt-6-astra-high-sidekick-swe-2-medium").0
        // No Workshop MCP connection or production runtime in this bounded probe.
        spec.mcpInjection = .acpSessionParam
        spec.env.removeValue(forKey: "WORKSHOP_MCP_PATH")
        var captured: ProcessACPTransport?
        let adapter = ACPHarnessAdapter(spec: spec, transportFactory: { spec, cwd in
            let transport = try ProcessACPTransport(argv: spec.argv, env: spec.env, cwd: cwd)
            captured = transport
            // Timeout bounds initialize and native turn even if ACP never replies.
            DispatchQueue.global().asyncAfter(deadline: .now() + 75) { transport.terminate() }
            return transport
        }, cancellationTimeout: .milliseconds(100))
        let tid = TaskID("task_native_writer_probe")
        let workspace = TaskWorkspace(taskID: tid, path: work, state: "writer")
        let binding = SessionBinding(taskID: tid, engineerID: .devin, role: "owner", workerID: "main", workspace: workspace)
        let ref: SessionRef
        do { ref = try await adapter.openTaskSession(binding: binding) }
        catch {
            XCTFail("Native startup: " + (captured?.stderrText ?? "no diagnostics"))
            throw error
        }
        let task = WorkshopTask(id: tid, channel: "tests", title: "Bounded writer probe", brief: "Write probe.txt in the current directory with exactly WORKSHOP_NATIVE_WRITER_OK. Read it back and report. No other work. Use your native file tools.", phase: .execution, state: .working, createdAt: Date(), updatedAt: Date())
        let context = TurnContext(task: task, subtask: nil, recentMessages: [], workspace: workspace)
        var completed = false
        for try await event in adapter.sendTurn(ref: ref, turnID: "probe", context: context, deadline: Date().addingTimeInterval(60)) {
            if event == .turnCompleted { completed = true }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(try String(contentsOfFile: work + "/probe.txt").trimmingCharacters(in: .whitespacesAndNewlines), "WORKSHOP_NATIVE_WRITER_OK")
        _ = await adapter.cancelTurn(ref: ref, turnID: "close-probe")
    }
}
