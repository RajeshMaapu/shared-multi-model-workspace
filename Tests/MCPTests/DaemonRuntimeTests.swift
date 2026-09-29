import XCTest
@testable import WorkshopDaemonKit
@testable import WorkshopIPC
@testable import WorkshopService
@testable import WorkshopCore

/// Start-up ordering: the UDS must accept requests as soon as `server.start()`
/// returns, even while post-listen work (balance refresh, canary sweep,
/// service recovery) is still running.
final class DaemonRuntimeTests: XCTestCase {
    func testListensBeforeSlowStartupWork() async throws {
        let home = NSTemporaryDirectory() + "wh-\(UUID().uuidString.prefix(8))"
        let runtimeDir = NSTemporaryDirectory() + "wr-\(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: runtimeDir)
        }
        var env = ProcessInfo.processInfo.environment
        env["WORKSHOP_ADAPTERS"] = "fake"
        env["WORKSHOP_RUNTIME_DIR"] = runtimeDir
        let rt = try DaemonRuntime(home: home, runtimeDir: runtimeDir, env: env)

        // Injected slow work: 3 s each. With the old ordering neither would
        // block a listener that starts first.
        rt.balanceRefresh = { try? await Task.sleep(for: .seconds(3)) }
        rt.canarySweep = { _, _, _ in try? await Task.sleep(for: .seconds(3)) }

        let userToken = try String(
            contentsOfFile: runtimeDir + "/user.token", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let startTask = Task { try await rt.start() }

        // The socket must answer authenticate within 1 s of start() being
        // called — the injected 3 s probes must not be on the listen path.
        let deadline = Date().addingTimeInterval(1)
        var authenticated = false
        var lastError: Error?
        while Date() < deadline && !authenticated {
            do {
                let client = WorkshopClient(socketPath: runtimeDir + "/service.sock")
                try await client.connect()
                let reply = try await client.call(
                    "workshop.authenticate",
                    params: .object(["token": .string(userToken)]))
                authenticated = reply["principal"]?.stringValue == "You"
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(authenticated,
                      "UDS did not accept authenticate within 1 s: "
                      + String(describing: lastError))
        try await startTask.value
        await rt.shutdown()
    }
}
