import Foundation
import os
import WorkshopCore
import WorkshopService

/// How MCP servers reach the harness.
public enum MCPInjection: Sendable {
    /// `session/new` `mcpServers` param (Kimi — verified by live probe).
    case acpSessionParam
    /// Project file `<cwd>/.devin/mcp_config.local.json` (Devin — ACP injection
    /// connects but `mcp_list_tools` cannot resolve servers not in config).
    case devinProjectConfigFile
}

/// Everything needed to launch one harness process.
public struct HarnessLaunchSpec: Sendable {
    public var engineer: EngineerID
    public var executable: String
    public var args: [String]
    public var env: [String: String]
    public var cwd: String
    public var sandboxProfilePath: String?
    public var mcpInjection: MCPInjection
    /// Version string qualified in probes; mismatch is reported, not blocked.
    public var qualifiedVersion: String
    /// Human-readable model selector for probe reporting.
    public var modelSelection: String?
    /// Binary to version-probe when `executable` is a launcher (sandbox-exec).
    public var versionProbePath: String?
    /// Per-task worktree root (<home>/worktrees); when set the session cwd is
    /// <worktreeRoot>/<task_id>, created on demand.
    public var worktreeRoot: String?

    /// argv for spawning: [executable] + args.
    public var argv: [String] { [executable] + args }

    public init(engineer: EngineerID, executable: String, args: [String],
                env: [String: String], cwd: String, sandboxProfilePath: String? = nil,
                mcpInjection: MCPInjection, qualifiedVersion: String,
                modelSelection: String? = nil) {
        self.engineer = engineer
        self.executable = executable
        self.args = args
        self.env = env
        self.cwd = cwd
        self.sandboxProfilePath = sandboxProfilePath
        self.mcpInjection = mcpInjection
        self.qualifiedVersion = qualifiedVersion
        self.modelSelection = modelSelection
        self.versionProbePath = nil
        self.worktreeRoot = nil
    }
}

/// Shared ACP harness adapter for Devin and Kimi. Keeps the process warm between
/// turns for the same session; bounded idle timeout.
public final class ACPHarnessAdapter: EngineerAdapter, @unchecked Sendable {
    public let engineer: EngineerID
    private let spec: HarnessLaunchSpec
    private let transportFactory: @Sendable (HarnessLaunchSpec, String) throws -> ACPTransport
    private let versionProbe: @Sendable (String) -> String?
    private let lock = NSLock()
    private var client: ACPClient?
    private var sessionID: String?
    private var lastActivity = Date.distantPast
    /// turnID → waiter resumed when the in-flight session/prompt call returns
    /// (T23 cancel acknowledgement) and turns whose prompt already finished.
    private var promptWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var promptFinished: Set<String> = []
    /// Notes produced outside a turn stream (e.g. session/load fallback);
    /// emitted as `.uncertain` at the start of the next sendTurn.
    private var pendingNotes: [String] = []
    private let log = Logger(subsystem: "ai.maapu.workshop", category: "adapter")

    public init(spec: HarnessLaunchSpec,
                transportFactory: @escaping @Sendable (HarnessLaunchSpec, String) throws -> ACPTransport
                    = { try ProcessACPTransport(argv: $0.argv, env: $0.env, cwd: $1) },
                versionProbe: @escaping @Sendable (String) -> String?
                    = ACPHarnessAdapter.defaultVersionProbe) {
        self.engineer = spec.engineer
        self.spec = spec
        self.transportFactory = transportFactory
        self.versionProbe = versionProbe
    }

    /// Probe binary presence + version. Never reports auth health from files.
    public nonisolated func probe() async -> AdapterProbe {
        let probePath = spec.versionProbePath ?? spec.executable
        guard FileManager.default.isExecutableFile(atPath: probePath) else {
            return AdapterProbe(engineer: engineer,
                                health: .unavailable("binary not found: \(probePath)"),
                                tested: false)
        }
        guard let version = versionProbe(probePath) else {
            return AdapterProbe(engineer: engineer,
                                health: .unavailable("version probe failed"),
                                tested: false)
        }
        let qualified = version == spec.qualifiedVersion
        let detail = qualified
            ? "v\(version) qualified; auth unverified until first turn"
            : "v\(version) UNTESTED (qualified \(spec.qualifiedVersion)); auth unverified until first turn"
        return AdapterProbe(engineer: engineer,
                            health: .available(detail),
                            versions: ["binary": version],
                            effectiveModel: spec.modelSelection,
                            capabilities: ["acp", "session_load"],
                            tested: qualified)
    }

    /// Default version probe: `<bin> --version`, 10 s bound. Overridable in tests.
    public static func defaultVersionProbe(_ path: String) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Bounded wait.
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        // Extract a semver-ish token.
        for token in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if token.first?.isNumber == true, token.contains(".") { return String(token) }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
        let cwd = sessionCwd(for: binding)
        try await ensureClient(cwd: cwd)
        guard let client else { throw WorkshopError.adapterUnavailable(engineer) }
        if spec.mcpInjection == .devinProjectConfigFile {
            writeDevinMCPConfig(cwd: cwd)
        }
        if let native = binding.nativeSessionID, sessionID == nil {  // lock-held read

            // Try to load the persisted native session; fall back to new.
            do {
                _ = try await client.call("session/load", params: .object([
                    "sessionId": .string(native), "cwd": .string(cwd),
                    "mcpServers": .array(mcpServersParam())]))
                sessionID = native
            } catch {
                sessionID = try await newSession(client: client, cwd: cwd)
                lock.lock()
                pendingNotes.append(
                    "Native session for \(engineer.rawValue) could not be loaded; "
                    + "started a new session (no checkpoint available yet)")
                lock.unlock()
            }
        } else if sessionID == nil {
            sessionID = try await newSession(client: client, cwd: cwd)
        }
        return SessionRef(engineer: engineer, nativeSessionID: sessionID ?? "")
    }

    private func newSession(client: ACPClient, cwd: String) async throws -> String {
        let result = try await client.call("session/new", params: .object([
            "cwd": .string(cwd), "mcpServers": .array(mcpServersParam())]))
        guard let id = result["sessionId"]?.stringValue else {
            throw WorkshopError.adapterUnavailable(engineer)
        }
        return id
    }

    /// Directory the harness session runs in: the per-task worktree when a
    /// worktree root is configured, else the spec cwd.
    private func sessionCwd(for binding: SessionBinding) -> String {
        guard let root = spec.worktreeRoot else { return spec.cwd }
        let home = (root as NSString).deletingLastPathComponent
        if let (path, _) = try? WorkspaceManager.prepareWorkspace(
            homeDir: home, taskID: binding.taskID, workspaceRef: nil) {
            return path
        }
        return spec.cwd
    }

    /// Bridge path + token file: the launch spec's env first (set by
    /// ProfileBuilder), then the process env (tests / manual runs).
    private func bridgeArgs() -> [JSONValue] {
        let env = spec.env
        let tokenKey = "WORKSHOP_TOKEN_\(engineer.rawValue.uppercased())"
        guard let bridge = env["WORKSHOP_MCP_PATH"]
                ?? ProcessInfo.processInfo.environment["WORKSHOP_MCP_PATH"],
              let tokenFile = env[tokenKey]
                ?? ProcessInfo.processInfo.environment[tokenKey] else {
            return []
        }
        return [.string("--engineer"), .string(engineer.rawValue),
                .string("--token-file"), .string(tokenFile)]
    }

    private func bridgeCommand() -> String? {
        spec.env["WORKSHOP_MCP_PATH"]
            ?? ProcessInfo.processInfo.environment["WORKSHOP_MCP_PATH"]
    }

    /// mcpServers param for session/new (empty for Devin; populated for Kimi).
    private func mcpServersParam() -> [JSONValue] {
        guard spec.mcpInjection == .acpSessionParam,
              let bridge = bridgeCommand(),
              !bridgeArgs().isEmpty else {
            return []
        }
        return [.object([
            "name": .string("workshop"),
            "command": .string(bridge),
            "args": .array(bridgeArgs()),
            "env": .array([]),
        ])]
    }

    /// Devin resolves MCP tools only from `<cwd>/.devin/mcp_config.local.json`.
    private func writeDevinMCPConfig(cwd: String) {
        guard let bridge = bridgeCommand(), !bridgeArgs().isEmpty else { return }
        let dir = cwd + "/.devin"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let config: [String: JSONValue] = ["mcpServers": .object([
            "workshop": .object([
                "command": .string(bridge),
                "args": .array(bridgeArgs()),
                "transport": .string("stdio"),
            ]),
        ])]
        guard let data = try? JSONEncoder().encode(JSONValue.object(config)) else { return }
        try? data.write(to: URL(fileURLWithPath: dir + "/mcp_config.local.json"))
        // Keep the file out of git status when the worktree is a repo.
        let exclude = cwd + "/.git/info/exclude"
        if FileManager.default.fileExists(atPath: exclude),
           let existing = try? String(contentsOfFile: exclude),
           !existing.contains(".devin/") {
            try? (existing + "\n.devin/\n").write(toFile: exclude, atomically: true,
                                                 encoding: .utf8)
        }
    }

    private func ensureClient(cwd: String) async throws {
        // Terminate a warm process after the idle bound.
        lock.lock()
        let stale = client != nil && Date().timeIntervalSince(lastActivity) > 600
        lock.unlock()
        if stale {
            await client?.close()
            lock.lock(); client = nil; sessionID = nil; lock.unlock()
        }
        guard client == nil else { return }
        let transport = try transportFactory(spec, cwd)
        let c = ACPClient(transport: transport)
        client = c
        _ = try await c.call("initialize", params: .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object([:]),
            "clientInfo": .object(["name": .string("workshop"), "version": .string("0")]),
        ]))
    }

    public func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                         deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
        let client = self.client
        let sid = ref.nativeSessionID
        let packet = context.packetText(for: engineer)
        let source = "acp:" + engineer.rawValue
        lock.lock()
        let notes = pendingNotes
        pendingNotes.removeAll()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            Task {
                var usageEmitted = false
                guard let client else {
                    continuation.finish(throwing: WorkshopError.adapterUnavailable(engineer))
                    return
                }
                continuation.yield(.turnStarted)
                for note in notes {
                    continuation.yield(.uncertain(note))
                }
                // The sink runs inside the client's read loop: session/update
                // notifications emitted mid-prompt are yielded before the
                // prompt result resumes this task (ordering, not racing).
                await client.setEventSink { event in
                    if case .sessionUpdate(let u) = event {
                        if let dir = ProcessInfo.processInfo.environment["WORKSHOP_DIAG_DIR"],
                           let data = try? JSONEncoder().encode(u) {
                            let p = dir + "/acp-updates-\(self.engineer.rawValue).log"
                            let line = String(decoding: data, as: UTF8.self) + "\n"
                            if let fh = FileHandle(forWritingAtPath: p) {
                                fh.seekToEndOfFile(); fh.write(Data(line.utf8)); fh.closeFile()
                            } else {
                                FileManager.default.createFile(atPath: p, contents: Data(line.utf8))
                            }
                        }
                        switch u["sessionUpdate"]?.stringValue {
                        case "agent_message_chunk":
                            if let t = u["content"]?["text"]?.stringValue {
                                continuation.yield(.messageDelta(t))
                            }
                        case "tool_call":
                            continuation.yield(.toolActivity(
                                title: u["title"]?.stringValue ?? "tool",
                                status: "started"))
                        case "tool_call_update":
                            continuation.yield(.toolActivity(
                                title: u["title"]?.stringValue ?? "tool",
                                status: u["status"]?.stringValue ?? "updated"))
                        default: break
                        }
                    } else if case .permissionDenied(let title) = event {
                        continuation.yield(.permissionDenied(title))
                    }
                }
                defer {
                    Task { await client.setEventSink(nil) }
                }
                do {
                    let result = try await client.call("session/prompt", params: .object([
                        "sessionId": .string(sid),
                        "prompt": .array([.object([
                            "type": .string("text"), "text": .string(packet)])]),
                    ]))
                    if let dir = ProcessInfo.processInfo.environment["WORKSHOP_DIAG_DIR"],
                       let data = try? JSONEncoder().encode(result) {
                        let p = dir + "/acp-prompt-result-\(self.engineer.rawValue).log"
                        let line = String(decoding: data, as: UTF8.self) + "\n"
                        if let fh = FileHandle(forWritingAtPath: p) {
                            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); fh.closeFile()
                        } else {
                            FileManager.default.createFile(atPath: p, contents: Data(line.utf8))
                        }
                    }
                    if let usage = result["usage"] {
                        usageEmitted = true
                        continuation.yield(.usageSample(
                            input: usage["inputTokens"]?.intValue.map(Int.init),
                            output: usage["outputTokens"]?.intValue.map(Int.init),
                            cacheRead: usage["cachedReadTokens"]?.intValue.map(Int.init),
                            cacheWrite: usage["cachedWriteTokens"]?.intValue.map(Int.init),
                            source: source))
                    }
                    if !usageEmitted {
                        // Some ACP servers (Kimi) report no usage; still record
                        // a row so callers can distinguish "unmeasured" from
                        // "turn never ran".
                        continuation.yield(.usageSample(
                            input: nil, output: nil, cacheRead: nil,
                            cacheWrite: nil, source: source))
                    }
                    continuation.yield(.turnCompleted)
                    continuation.finish()
                } catch let error as ACPClient.ACPError {
                    if case .remote(let code, _) = error, code == -32000 || code == -32001 {
                        continuation.yield(.authRequired)
                    }
                    continuation.finish(throwing: error)
                }
                self.touchActivity()
                self.finishPrompt(turnID: turnID)
            }
        }
    }

    private func finishPrompt(turnID: String) {
        lock.lock()
        promptFinished.insert(turnID)
        let waiter = promptWaiters.removeValue(forKey: turnID)
        lock.unlock()
        waiter?.resume()
    }

    /// Resolves when the turn's session/prompt call returns (any outcome).
    private func awaitPromptFinish(turnID: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if promptFinished.contains(turnID) {
                lock.unlock()
                c.resume()
            } else {
                promptWaiters[turnID] = c
                lock.unlock()
            }
        }
    }

    private func touchActivity() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    /// T23: send session/cancel, then wait ≤10 s for the prompt call to
    /// return. No response → kill the process group and report uncertain.
    public func cancelTurn(ref: SessionRef, turnID: String) async -> Bool {
        guard let client else { return false }
        _ = try? await client.call("session/cancel", params: .object([
            "sessionId": .string(ref.nativeSessionID)]))
        let acknowledged = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.awaitPromptFinish(turnID: turnID); return true }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !acknowledged {
            await client.close()
            lock.lock()
            self.client = nil
            self.sessionID = nil
            lock.unlock()
        }
        return acknowledged
    }
}

