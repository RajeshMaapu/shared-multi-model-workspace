import XCTest
@testable import WorkshopDaemonKit
@testable import WorkshopService
@testable import WorkshopCore

/// G-D8: fake adapters must never run against the installed Workshop home.
final class DaemonAdapterGuardTests: XCTestCase {
    private var home = ""
    private var runtimeDir = ""
    private var runtime: DaemonRuntime?

    override func tearDown() async throws {
        if let runtime { await runtime.shutdown() }
        runtime = nil
        if !home.isEmpty { try? FileManager.default.removeItem(atPath: home) }
        if !runtimeDir.isEmpty {
            try? FileManager.default.removeItem(atPath: runtimeDir)
        }
    }

    private func env(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WORKSHOP_RUNTIME_DIR"] = runtimeDir
        env["WORKSHOP_MCP_PORT"] = "0"
        for (k, v) in extra { env[k] = v }
        return env
    }

    private func makeDirs() {
        home = NSTemporaryDirectory() + "wh-guard-\(UUID().uuidString.prefix(8))"
        runtimeDir = NSTemporaryDirectory() + "wr-guard-\(UUID().uuidString.prefix(8))"
    }

    /// Any temp (non-installed) home still accepts fake adapters.
    func testFakeAdaptersAllowedOnNonInstalledHome() throws {
        makeDirs()
        runtime = try DaemonRuntime(
            home: home, runtimeDir: runtimeDir,
            env: env(["WORKSHOP_ADAPTERS": "fake"]))
        XCTAssertTrue(runtime?.adapters.allSatisfy { $0 is FakeAdapter } ?? false)
    }

    /// When the home canonicalizes to the installed home, fake adapters are
    /// refused at init; an explicit override is required for a test.
    func testFakeAdaptersRefusedOnInstalledHome() throws {
        makeDirs()
        var guardEnv = env([
            "WORKSHOP_ADAPTERS": "fake",
            "WORKSHOP_INSTALLED_HOME_OVERRIDE": home,
        ])
        XCTAssertThrowsError(
            try DaemonRuntime(home: home, runtimeDir: runtimeDir, env: guardEnv)
        ) { error in
            XCTAssertTrue(error.localizedDescription
                .contains("Refusing fake adapters"))
        }

        guardEnv["WORKSHOP_ALLOW_FAKE_ON_INSTALLED_HOME"] = "1"
        runtime = try DaemonRuntime(home: home, runtimeDir: runtimeDir,
                                    env: guardEnv)
        XCTAssertTrue(runtime?.adapters.allSatisfy { $0 is FakeAdapter } ?? false)
    }

    /// With WORKSHOP_ADAPTERS unset, the installed home defaults to live.
    func testInstalledHomeDefaultsToLiveAdapters() throws {
        makeDirs()
        var liveEnv = env(["WORKSHOP_INSTALLED_HOME_OVERRIDE": home])
        liveEnv.removeValue(forKey: "WORKSHOP_ADAPTERS")
        runtime = try DaemonRuntime(
            home: home, runtimeDir: runtimeDir, env: liveEnv)
        XCTAssertTrue(runtime?.adapters.allSatisfy {
            !($0 is FakeAdapter) } ?? false)
    }
}
