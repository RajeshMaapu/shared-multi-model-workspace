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
    /// Daemon-hosted Streamable HTTP MCP endpoint; when set (and a token is
    /// readable) the harness connects over HTTP instead of the stdio shim.
    public var mcpURL: String?

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
        self.mcpURL = nil
    }
}

/// A harness handshake/session operation failed. Carries the remote ACP error
/// (or launch failure) plus the child's own stderr tail so native causes —
/// e.g. a team-settings fetch timing out — survive to the system event.
public struct HarnessSessionError: Error, LocalizedError, Equatable {
    public let engineer: EngineerID
    public let operation: String
    public let underlying: String
    public let stderrTail: String

    public init(engineer: EngineerID, operation: String, underlying: String,
                stderrTail: String) {
        self.engineer = engineer
        self.operation = operation
        self.underlying = underlying
        self.stderrTail = stderrTail
    }

    public var errorDescription: String? {
        var text = "\(engineer.rawValue) \(operation) failed: \(underlying)"
        if !stderrTail.isEmpty {
            text += " — harness stderr tail: " + stderrTail
        }
        return text
    }
}

/// Shared ACP harness adapter for Devin and Kimi. Keeps the process warm between
/// turns for the same session; bounded idle timeout.
public final class ACPHarnessAdapter: CapabilityAwareAdapter, @unchecked Sendable {
    public let engineer: EngineerID
    /// Configured model selector, propagated to session bindings and usage rows.
    public var modelSelection: String? { spec.modelSelection }
    /// Qualified only when config/capabilities.json records a passed
    /// isolated-writer recipe for this (engineer, native, model) identity
    /// (G-E5) — the launch still requires the fenced-generation plumbing.
    public var supportsIsolatedWorkspaceTurns: Bool {
        spec.sandboxProfilePath != nil && spec.worktreeRoot != nil
            && qualificationIdentity.flatMap {
                capabilityLookup?($0)?.qualified
            } ?? false
    }
    /// Phase 3c: capability records are data, injected by DaemonRuntime.
    public var capabilityLookup: (@Sendable (QualificationIdentity) -> CapabilityRecord?)?
    /// Appended to probe detail when the recorded binary hash drifted.
    public var binaryDriftNotice: String?
    public var qualificationIdentity: QualificationIdentity? {
        QualificationIdentity(engineer: engineer, lane: "native",
                              model: spec.modelSelection)
    }
    public var qualificationBinaryPath: String? {
        spec.versionProbePath ?? spec.executable
    }
    private let spec: HarnessLaunchSpec
    private let transportFactory: @Sendable (HarnessLaunchSpec, String) throws -> ACPTransport
    private let versionProbe: @Sendable (String) -> String?
    private let lock = NSLock()
    private var client: ACPClient?
    private var sessionID: String?
    private var activeTaskID: TaskID?
    private var activeWorkspacePath: String?
    private var lastActivity = Date.distantPast
    /// turnID → waiter resumed when the in-flight session/prompt call returns
    /// (T23 cancel acknowledgement) and turns whose prompt already finished.
    private let cancellationTimeout: Duration
    private let sessionLoadTimeout: Duration
    private var promptFinished: Set<String> = []
    /// Notes produced outside a turn stream (e.g. session/load fallback);
    /// emitted as `.uncertain` at the start of the next sendTurn.
    private var pendingNotes: [String] = []
    private let log = Logger(subsystem: "ai.maapu.workshop", category: "adapter")

    public init(spec: HarnessLaunchSpec,
                transportFactory: @escaping @Sendable (HarnessLaunchSpec, String) throws -> ACPTransport
                    = { try ProcessACPTransport(argv: $0.argv, env: $0.env, cwd: $1) },
                versionProbe: @escaping @Sendable (String) -> String?
                    = ACPHarnessAdapter.defaultVersionProbe,
                cancellationTimeout: Duration = .seconds(10),
                sessionLoadTimeout: Duration = .seconds(15)) {
        self.cancellationTimeout = cancellationTimeout
        self.sessionLoadTimeout = sessionLoadTimeout
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
        // The version probe is advisory: a timeout or empty reply means the
        // binary may still work, so the adapter stays available and the wakeup
        // path retries launches instead of dropping work (G-D5).
        guard let version = versionProbe(probePath) else {
            return AdapterProbe(engineer: engineer,
                                health: .available("version unknown (probe failed); auth unverified until first turn" + (binaryDriftNotice.map { " — " + $0 } ?? "")),
                                versions: [:],
                                effectiveModel: spec.modelSelection,
                                capabilities: ["acp", "session_load"],
                                tested: false)
        }
        let qualified = version == spec.qualifiedVersion
        var detail = qualified
            ? "v\(version) qualified; auth unverified until first turn"
            : "v\(version) UNTESTED (qualified \(spec.qualifiedVersion)); auth unverified until first turn"
        if let notice = binaryDriftNotice { detail += " — \(notice)" }
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
        guard binding.profileRevision >= 2 else {
            throw WorkshopError.invalidRequest("Legacy instruction profile requires a fresh task")
        }
        let requestedCwd = try sessionCwd(for: binding)
        if client != nil && (activeTaskID != binding.taskID || activeWorkspacePath != requestedCwd) {
            await client?.close()
            client = nil
            sessionID = nil
        }
        activeTaskID = binding.taskID
        let cwd = requestedCwd
        activeWorkspacePath = cwd
        let priorWorkspace = priorKimiWorkspace(for: binding, currentCwd: cwd)
        // Devin discovers project MCP servers while initializing its native
        // process. Install this generation's scoped token config before that
        // process starts, including when session/load will reuse its history.
        if spec.mcpInjection == .devinProjectConfigFile {
            try writeDevinMCPConfig(cwd: cwd)
        }
        try await ensureClient(cwd: cwd, taskID: binding.taskID.rawValue,
                               readOnlyPriorWorkspace: priorWorkspace)
        guard let client else { throw WorkshopError.adapterUnavailable(engineer) }
        if let native = binding.nativeSessionID, sessionID == nil {
            // Preserve native context across fenced generations. A bounded
            // load keeps a stale or inaccessible session from blocking the task.
            do {
                _ = try await client.call("session/load", params: .object([
                    "sessionId": .string(native), "cwd": .string(cwd),
                    "mcpServers": .array(mcpServersParam())]),
                    timeout: sessionLoadTimeout)
                sessionID = native
            } catch {
                let why = workshopErrorDescription(error)
                let fallbackClient: ACPClient
                if case ACPClient.ACPError.timeout = error {
                    await client.close()
                    self.client = nil
                    try await ensureClient(cwd: cwd, taskID: binding.taskID.rawValue,
                                           readOnlyPriorWorkspace: priorWorkspace)
                    guard let restarted = self.client else {
                        throw WorkshopError.adapterUnavailable(engineer)
                    }
                    fallbackClient = restarted
                } else {
                    fallbackClient = client
                }
                sessionID = try await newSession(client: fallbackClient, cwd: cwd)
                lock.lock()
                pendingNotes.append(
                    "Native session for \(engineer.rawValue) could not be loaded "
                    + "(\(why)); started a new session (no checkpoint available yet)")
                lock.unlock()
            }
        } else if sessionID == nil {
            sessionID = try await newSession(client: client, cwd: cwd)
        }
        return SessionRef(engineer: engineer, nativeSessionID: sessionID ?? "")
    }

    /// Last non-empty stderr lines from the child — where the harness reports
    /// its own connection failures (team settings, auth, upstream timeouts).
    private func stderrExcerpt(_ client: ACPClient) -> String {
        let tail = client.transportStderrText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: " | ")
        return String(tail.suffix(600))
    }

    private func newSession(client: ACPClient, cwd: String) async throws -> String {
        let result: JSONValue
        do {
            result = try await client.call("session/new", params: .object([
                "cwd": .string(cwd), "mcpServers": .array(mcpServersParam())]),
                timeout: .seconds(90))
        } catch {
            await client.close()
            self.client = nil
            sessionID = nil
            throw HarnessSessionError(
                engineer: engineer, operation: "session/new",
                underlying: workshopErrorDescription(error),
                stderrTail: stderrExcerpt(client))
        }
        guard let id = result["sessionId"]?.stringValue else {
            throw HarnessSessionError(
                engineer: engineer, operation: "session/new",
                underlying: "response contained no sessionId",
                stderrTail: stderrExcerpt(client))
        }
        return id
    }

    /// Directory the harness session runs in: the per-task worktree when a
    /// worktree root is configured, else the spec cwd.
    private func sessionCwd(for binding: SessionBinding) throws -> String {
        if let workspace = binding.workspace { return workspace.path }
        guard let root = spec.worktreeRoot else { return spec.cwd }
        let home = (root as NSString).deletingLastPathComponent
        return try WorkspaceManager.prepareTaskWorkspace(
            homeDir: home, taskID: binding.taskID, workspaceRef: nil).path
    }

    /// Token file for this engineer: the generation-scoped token
    /// `<cwd>/../token` when the session runs under writer-runs, else
    /// `WORKSHOP_TOKEN_<ENGINEER>` from the spec env or the process env.
    private func effectiveTokenPath() -> String? {
        if let cwd = activeWorkspacePath, cwd.contains("/writer-runs/") {
            return (cwd as NSString).deletingLastPathComponent + "/token"
        }
        let tokenKey = "WORKSHOP_TOKEN_\(engineer.rawValue.uppercased())"
        return spec.env[tokenKey]
            ?? ProcessInfo.processInfo.environment[tokenKey]
    }

    /// Trimmed token file contents, or nil when unreadable/empty.
    private func readToken() -> String? {
        guard let path = effectiveTokenPath(),
              let token = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Bridge path + token file: the launch spec's env first (set by
    /// ProfileBuilder), then the process env (tests / manual runs).
    private func bridgeArgs() -> [JSONValue] {
        let env = spec.env
        guard let bridge = env["WORKSHOP_MCP_PATH"]
                ?? ProcessInfo.processInfo.environment["WORKSHOP_MCP_PATH"],
              let tokenFile = effectiveTokenPath() else {
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
    /// With a daemon HTTP endpoint and a readable token, send the Streamable
    /// HTTP variant probed against kimi 2.1.1; otherwise the stdio shim.
    private func mcpServersParam() -> [JSONValue] {
        guard spec.mcpInjection == .acpSessionParam else { return [] }
        if let url = spec.mcpURL, let token = readToken() {
            return [.object([
                "type": .string("http"),
                "name": .string("workshop"),
                "url": .string(url),
                "headers": .array([.object([
                    "name": .string("Authorization"),
                    "value": .string("Bearer \(token)")])]),
            ])]
        }
        guard let bridge = bridgeCommand(), !bridgeArgs().isEmpty else {
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
    private func writeDevinMCPConfig(cwd: String) throws {
        var server: JSONValue?
        if let url = spec.mcpURL, let token = readToken() {
            server = .object([
                "url": .string(url),
                "transport": .string("http"),
                "headers": .object([
                    "Authorization": .string("Bearer \(token)")]),
            ])
        } else if let bridge = bridgeCommand(), !bridgeArgs().isEmpty {
            server = .object([
                "command": .string(bridge),
                "args": .array(bridgeArgs()),
                "transport": .string("stdio"),
            ])
        }
        guard let server else {
            throw WorkshopError.invalidRequest("Devin MCP bridge or token unavailable")
        }
        let dir = cwd + "/.devin"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let config: [String: JSONValue] = ["mcpServers": .object(["workshop": server])]
        let data = try JSONEncoder().encode(JSONValue.object(config))
        let configPath = dir + "/mcp_config.local.json"
        try data.write(to: URL(fileURLWithPath: configPath))
        chmod(configPath, 0o600)
        // Keep the file out of git status when the worktree is a repo:
        // create .git/info/exclude when missing (fresh generations have a
        // .git dir but no exclude file yet).
        let fm = FileManager.default
        var isDir = ObjCBool(false)
        if fm.fileExists(atPath: cwd + "/.git", isDirectory: &isDir), isDir.boolValue {
            let infoDir = cwd + "/.git/info"
            try? fm.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
            let exclude = infoDir + "/exclude"
            if !fm.fileExists(atPath: exclude) {
                try? "".write(toFile: exclude, atomically: true, encoding: .utf8)
            }
            if let existing = try? String(contentsOfFile: exclude),
               !existing.contains(".devin/") {
                try? (existing + "\n.devin/\n").write(toFile: exclude, atomically: true,
                                                     encoding: .utf8)
            }
        }
    }

    /// Read-only prior-workspace grant for a warm Kimi session. The granted
    /// path is the task's current fenced review seed — the same snapshot
    /// begin() seeded this turn from — never a stale session-index path.
    private func priorKimiWorkspace(for binding: SessionBinding,
                                    currentCwd: String) -> String? {
        guard engineer == .kimi, binding.nativeSessionID != nil,
              spec.sandboxProfilePath != nil,
              let seed = binding.reviewSeedPath,
              seed != currentCwd else { return nil }
        return seed
    }

    private func ensureClient(cwd: String, taskID: String,
                              readOnlyPriorWorkspace: String? = nil,
                              startupAttempt: Int = 0) async throws {
        // Terminate a warm process after the idle bound.
        lock.lock()
        let stale = client != nil && Date().timeIntervalSince(lastActivity) > 600
        lock.unlock()
        if stale {
            await client?.close()
            lock.lock(); client = nil; sessionID = nil; lock.unlock()
        }
        guard client == nil else { return }
        var launch = spec
        if let sandbox = spec.sandboxProfilePath, let root = spec.worktreeRoot {
            let home = (root as NSString).deletingLastPathComponent
            if cwd.hasPrefix(home + "/writer-runs/") {
                let profile = (sandbox as NSString).deletingLastPathComponent
                try ProfileBuilder.writerSandboxProfile(workshopHome: home, worktree: cwd,
                    profile: profile, token: (cwd as NSString).deletingLastPathComponent + "/token",
                    destination: sandbox, engineer: spec.engineer,
                    readOnlyPriorWorkspace: readOnlyPriorWorkspace)
                let tmp = (cwd as NSString).deletingLastPathComponent + "/tmp"
                try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
                launch.env["TMPDIR"] = tmp
                launch.env["PYTHONDONTWRITEBYTECODE"] = "1"
                launch.env["PATH"] = NSHomeDirectory() + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            } else {
                try ProfileBuilder.devinSandboxProfile(workshopHome: home, worktree: cwd, destination: sandbox)
            }
        }
        let transport = try transportFactory(launch, cwd)
        let c = ACPClient(transport: transport)
        do {
            _ = try await c.call("initialize", params: .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([:]),
                "clientInfo": .object(["name": .string("workshop"), "version": .string("0")]),
            ]))
        } catch {
            // A failed handshake leaves no usable client; drop it so the next
            // turn respawns instead of reusing a half-initialized transport.
            let tail = stderrExcerpt(c)
            await c.close()
            // Retry only the observed transient launcher timeout, before a
            // native prompt can run. Keep the same binding/workspace; never
            // retry authentication, sandbox rejection, or uncertain prompts.
            let detail = workshopErrorDescription(error) + " " + tail
            if !Task.isCancelled, startupAttempt < 2,
               detail.contains("fusion-relay: timed out") {
                try await Task.sleep(for: .seconds(startupAttempt == 0 ? 1 : 3))
                try Task.checkCancellation()
                try await ensureClient(cwd: cwd, taskID: taskID,
                    readOnlyPriorWorkspace: readOnlyPriorWorkspace,
                    startupAttempt: startupAttempt + 1)
                return
            }
            throw HarnessSessionError(
                engineer: engineer, operation: "initialize",
                underlying: workshopErrorDescription(error), stderrTail: tail)
        }
        client = c
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
                                status: "started", callID: u["toolCallId"]?.stringValue))
                        case "tool_call_update":
                            continuation.yield(.toolActivity(
                                title: u["title"]?.stringValue ?? "tool",
                                status: u["status"]?.stringValue ?? "updated", callID: u["toolCallId"]?.stringValue))
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
                    await client.setCapabilities(context.capabilities)
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
        lock.unlock()
    }

    private func isPromptFinished(_ turnID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return promptFinished.contains(turnID)
    }

    private func clearClient() {
        lock.lock(); defer { lock.unlock() }
        client = nil
        sessionID = nil
    }

    private func touchActivity() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    /// The live client's capability manifest — exposed for adapter tests.
    public func currentCapabilities() async -> TurnCapabilityManifest? {
        lock.lock(); let c = client; lock.unlock()
        return await c?.currentCapabilities
    }

    /// ACP v1 cancellation is a notification. Bound the wait for the original
    /// prompt, including agents that never respond to cancellation. A returned
    /// prompt is protocol acknowledgment, NOT proof of descendant quiescence.
    public func cancelTurn(ref: SessionRef, turnID: String) async -> Bool {
        guard let client else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: cancellationTimeout)
        do {
            try await client.notify("session/cancel", params: .object([
                "sessionId": .string(ref.nativeSessionID)]))
            while !Task.isCancelled && clock.now < deadline {
                if isPromptFinished(turnID) { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            // Transport failure or caller cancellation must also close the client.
        }
        await client.close()
        clearClient()
        return false
    }
}
