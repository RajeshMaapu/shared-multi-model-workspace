import XCTest
import Foundation
@testable import WorkshopAdapters
@testable import WorkshopCore

private final class InspectingTransport: ACPTransport, @unchecked Sendable {
    struct ShapeRecord: Sendable {
        var event: String
        var fieldKeys: [String]
        var metadata: [String: String]
        var normalizedTool: String
        var kind: String
        var inputKeys: [String]
        var commandMatchesApproved: Bool
        var commandFieldPresent: Bool
        var workdirMatchesWorkspace: Bool
        var optionKinds: [String]
    }
    private let base: ACPTransport
    private let workspace: String
    private let approvedCommand: String
    private let lock = NSLock()
    private(set) var records: [ShapeRecord] = []
    let lines: AsyncStream<String>
    init(base: ACPTransport, workspace: String, approvedCommand: String) {
        self.base = base
        self.workspace = workspace
        self.approvedCommand = approvedCommand
        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        let cont = continuation!
        Task {
            for await line in base.lines {
                self.inspect(line)
                cont.yield(line)
            }
            cont.finish()
        }
    }
    func send(_ line: String) throws { try base.send(line) }
    func terminate() { base.terminate() }
    private static let keyPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_./:-]{1,100}$")
    private static let toolPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_:.-]{1,100}$")
    private static func safeKey(_ key: String) -> String {
        keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil ? key : "<redacted>"
    }
    private func inspect(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = msg else { return }
        let method = object["method"]?.stringValue ?? ""
        var event: String?
        var toolCall: JSONValue?
        var options: JSONValue?
        if method == "session/request_permission" {
            event = "request_permission"
            toolCall = object["params"]?["toolCall"]
            options = object["params"]?["options"]
        } else if method == "session/update",
                  let update = object["params"]?["update"],
                  let updateKind = update["sessionUpdate"]?.stringValue,
                  updateKind == "tool_call" || updateKind == "tool_call_update" {
            event = "session_update_" + updateKind
            toolCall = update
        }
        guard let event, let toolCall else { return }
        func sortedKeys(_ value: JSONValue?) -> [String] {
            guard case .object(let fields)? = value else { return [] }
            return fields.keys.map(Self.safeKey).sorted()
        }
        func metadataMap(_ value: JSONValue?) -> [String: String] {
            guard case .object(let fields)? = value else { return [:] }
            var map: [String: String] = [:]
            for (key, field) in fields {
                let safe = Self.safeKey(key)
                var type: String
                var scalar: String?
                switch field {
                case .string(let text): type = "string"; scalar = text
                case .number: type = "number"
                case .bool: type = "bool"
                case .null: type = "null"
                case .array: type = "array"
                case .object: type = "object"
                }
                if key.hasSuffix("/toolName") || key.hasSuffix("/tool_name") || key.hasSuffix("/tool"),
                   let scalar,
                   Self.toolPattern.firstMatch(in: scalar, range: NSRange(scalar.startIndex..., in: scalar)) != nil {
                    map[safe] = type + ":" + scalar
                } else {
                    map[safe] = type
                }
            }
            return map
        }
        let rawName = toolCall["_meta"]?["cognition.ai/toolName"]?.stringValue ?? ""
        let normalizedTool = Self.toolPattern.firstMatch(in: rawName, range: NSRange(rawName.startIndex..., in: rawName)) != nil && !rawName.isEmpty ? rawName : "<unknown>"
        let rawKind = toolCall["kind"]?.stringValue ?? ""
        let knownKinds: Set<String> = ["read", "edit", "delete", "move", "search", "execute", "think", "fetch", "switch_mode", "other"]
        let kind = knownKinds.contains(rawKind) ? rawKind : (rawKind.isEmpty ? "<empty>" : "unknown")
        let input = toolCall["rawInput"]
        let command = input?["command"]?.stringValue
        let workdir = input?["workdir"]?.stringValue
        let normalizedWorkdir = workdir.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        var optionKinds: [String] = []
        if case .array(let list)? = options {
            let known: Set<String> = ["allow_once", "allow_always", "reject_once", "reject_always"]
            optionKinds = list.map { entry in
                let k = entry["kind"]?.stringValue ?? ""
                return known.contains(k) ? k : "unknown"
            }
        }
        let record = ShapeRecord(
            event: event,
            fieldKeys: sortedKeys(toolCall),
            metadata: metadataMap(toolCall["_meta"]),
            normalizedTool: normalizedTool,
            kind: kind,
            inputKeys: sortedKeys(input),
            commandMatchesApproved: command == approvedCommand,
            commandFieldPresent: command != nil,
            workdirMatchesWorkspace: normalizedWorkdir == workspace,
            optionKinds: optionKinds)
        lock.lock()
        if records.count < 20 { records.append(record) }
        lock.unlock()
    }
    func snapshot() -> [ShapeRecord] { lock.lock(); defer { lock.unlock() }; return records }
}

final class NativeRemediationProbeTests: XCTestCase {
    func testScopedCommandAndNativeSessionPersistence() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WORKSHOP_NATIVE_REMEDIATION_PROBE"] == "1", "Explicit isolated native qualification only")
        let fm = FileManager.default
        let root = "/private/tmp/ws-native-" + UUID().uuidString
        let workspace = root + "/writer-runs/probe/workspace"
        try fm.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let fixture = workspace + "/approved-inputs.json"
        try "{\"fixture\":\"WORKSHOP_FROZEN_INPUTS_OK\",\"source\":\"synthetic\"}".write(toFile: fixture, atomically: true, encoding: .utf8)
        let nativeBinary = NSHomeDirectory() + "/.local/bin/devin"
        let relaySource = NSHomeDirectory() + "/projects/fusion-codex-relay"
        let profile = try ProfileBuilder.devinProfile(home: root, model: "fusion-gpt-6-astra-high-sidekick-swe-2-medium")
        let wrapper = root + "/writer-runs/probe/reuse-fusion"
        let wrapperSource = """
        #!/usr/bin/python3
        import os,sys
        sys.path.insert(0,sys.argv[1])
        from fusion_relay import launcher as l
        from fusion_relay.identity import PrivateDirectory
        with PrivateDirectory(l.DATA_DIR) as private:
            conn=l._verified_conn(l._env_port(),private)
            conn.close()
            token=l._read_token(private)
        endpoint=l._endpoint(l._env_port())
        env=dict(os.environ,WINDSURF_API_SERVER_URL=endpoint+'/t/'+token)
        os.execve(sys.argv[2],[sys.argv[2],*sys.argv[3:]],env)
        """
        try wrapperSource.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper)
        let sb = profile + "/isolation.sb"
        try ProfileBuilder.writerSandboxProfile(workshopHome: root, worktree: workspace, profile: profile,
            token: root + "/writer-runs/probe/token", destination: sb)
        let tmp = root + "/writer-runs/probe/tmp"
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var env = ProfileBuilder.strippedEnv(profile: profile)
        env["TMPDIR"] = tmp
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        let policy = ACPPermissionPolicy(workspace: workspace, approvedCommands: [ACPCommandApproval(command: "/usr/bin/true", cwd: workspace)])
        let argv = ["/usr/bin/sandbox-exec", "-f", sb, "/usr/bin/python3", wrapper, relaySource, nativeBinary,
            "--config", profile + "/config/devin/config.json", "--permission-mode", "accept-edits", "acp"]
        func connect() async throws -> (ACPClient, ProcessACPTransport, InspectingTransport) {
            let transport = try ProcessACPTransport(argv: argv, env: env, cwd: workspace)
            DispatchQueue.global().asyncAfter(deadline: .now() + 100) { transport.terminate() }
            let inspecting = InspectingTransport(base: transport, workspace: workspace, approvedCommand: "/usr/bin/true")
            let client = ACPClient(transport: inspecting, permissionPolicy: policy)
            do {
                _ = try await client.call("initialize", params: .object(["protocolVersion": .number(1), "clientCapabilities": .object([:]), "clientInfo": .object(["name": .string("workshop-qualification"), "version": .string("1")])]))
            } catch {
                transport.terminate()
                throw error
            }
            return (client, transport, inspecting)
        }
        let (first, firstTransport, firstInspecting) = try await connect()
        defer { firstTransport.terminate() }
        let created = try await first.call("session/new", params: .object(["cwd": .string(workspace), "mcpServers": .array([])]))
        let session = try XCTUnwrap(created["sessionId"]?.stringValue)
        final class Capture: @unchecked Sendable {
            let lock = NSLock()
            var text = ""
            var decisions: [ACPPermissionDecision] = []
            var execID: String?
            var execCompleted = false
            func resetText() { lock.lock(); text = ""; lock.unlock() }
            func receive(_ event: ACPClient.ServerEvent) {
                lock.lock(); defer { lock.unlock() }
                if case .sessionUpdate(let update) = event,
                   update["sessionUpdate"]?.stringValue == "agent_message_chunk" { text += update["content"]?["text"]?.stringValue ?? "" }
                if case .sessionUpdate(let update) = event {
                    if update["kind"]?.stringValue == "execute",
                       update["rawInput"]?["command"]?.stringValue == "/usr/bin/true" {
                        execID = update["toolCallId"]?.stringValue
                    }
                    if let execID, update["toolCallId"]?.stringValue == execID,
                       update["status"]?.stringValue == "completed" { execCompleted = true }
                }
                if case .permissionDecision(let decision) = event { decisions.append(decision) }
            }
        }
        let initial = Capture()
        await first.setEventSink { initial.receive($0) }
        let prompt = "Bounded synthetic qualification only. Read approved-inputs.json in the current workspace using your native read tool. Run exactly /usr/bin/true once using your native exec tool, without wrapping, chaining, extra shell environment, or a different working directory. Do not modify files or access anything outside this workspace. Report the actual read marker and command exit status. Remember the session-only marker WORKSHOP_RESUME_COPPER_47 for a later turn, but do not write this marker to any file. No other work or subagents."
        _ = try await first.call("session/prompt", params: .object(["sessionId": .string(session), "prompt": .array([.object(["type": .string("text"), "text": .string(prompt)])])]))
        try await Task.sleep(for: .seconds(2))
        await first.close()
        let db = profile + "/data/devin/cli/sessions.db"
        let stateExists = fm.fileExists(atPath: db)
        let readMarker = initial.text.contains("WORKSHOP_FROZEN_INPUTS_OK")
        let execApproved = initial.decisions.contains { $0.operation == "execute" && $0.allowed && $0.reason == "exact_command_approval" }
        let cannotOpen = firstTransport.stderrText.contains("CannotOpen")
        let shapes = firstInspecting.snapshot().map { record -> [String: Any] in
            ["event": record.event, "field_keys": record.fieldKeys, "metadata": record.metadata,
             "normalized_tool": record.normalizedTool, "kind": record.kind, "input_keys": record.inputKeys,
             "command_matches_approved": record.commandMatchesApproved, "command_field_present": record.commandFieldPresent,
             "workdir_matches_workspace": record.workdirMatchesWorkspace, "option_kinds": record.optionKinds]
        }
        print("NATIVESHAPE " + String(decoding: try JSONSerialization.data(withJSONObject: shapes, options: [.sortedKeys]), as: UTF8.self))
        print("NATIVE_QUALIFICATION " + String(decoding: try JSONSerialization.data(withJSONObject: ["input_marker_observed": readMarker, "exact_exec_permission_observed": execApproved, "session_database_exists": stateExists, "permission_reasons": initial.decisions.map { $0.reason }, "stderr_cannot_open": cannotOpen], options: [.sortedKeys]), as: UTF8.self))
        XCTAssertTrue(readMarker)
        XCTAssertTrue(execApproved)
        XCTAssertTrue(initial.execCompleted)
        print("NATIVE_EXEC_COMPLETED " + String(initial.execCompleted))
        XCTAssertTrue(stateExists)
        guard stateExists else { return }
        let check = Process(); let out = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        check.arguments = ["-readonly", db, "PRAGMA integrity_check;"]
        check.standardOutput = out; check.standardError = FileHandle.nullDevice
        try check.run()
        let integrity = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertEqual(integrity, "ok")
        let (second, secondTransport, _) = try await connect()
        defer { secondTransport.terminate() }
        let resumed = Capture()
        await second.setEventSink { resumed.receive($0) }
        _ = try await second.call("session/load", params: .object(["sessionId": .string(session), "cwd": .string(workspace), "mcpServers": .array([])]))
        resumed.resetText()
        _ = try await second.call("session/prompt", params: .object(["sessionId": .string(session), "prompt": .array([.object(["type": .string("text"), "text": .string("Reply with the exact session-only marker from the previous turn. Do not use tools or read files. No other work.")])])]))
        await second.close()
        let recalled = resumed.text.contains("WORKSHOP_RESUME_COPPER_47")
        print("NATIVE_RESUME " + String(recalled))
        XCTAssertTrue(recalled)
        try assertNativePersistence(profile: profile)
    }

    private func assertNativePersistence(profile: String) throws {
        let check = Process(); let out = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        check.arguments = ["-readonly", profile + "/data/devin/cli/sessions.db",
                           "SELECT count(*) FROM sqlite_schema WHERE type='table';"]
        check.standardOutput = out; check.standardError = FileHandle.nullDevice
        try check.run()
        let count = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertGreaterThan(Int(count) ?? 0, 0)
        let logs = profile + "/data/devin/cli/logs"
        let files = try FileManager.default.contentsOfDirectory(atPath: logs).filter { $0.hasSuffix(".log") }
        XCTAssertFalse(files.isEmpty)
        let failed = try files.contains { name in
            let text = try String(contentsOfFile: logs + "/" + name)
            return text.contains("session DB open failed") || text.contains("forest autosave failed")
        }
        print("NATIVE_PERSISTENCE_ERRORS " + String(failed))
        XCTAssertFalse(failed)
    }

    func testNativeSessionCreationWithPrecreatedDatabase() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WORKSHOP_NATIVE_REMEDIATION_PROBE"] == "1", "Explicit isolated native qualification only")
        let fm = FileManager.default
        let root = "/private/tmp/ws-native-" + UUID().uuidString
        let workspace = root + "/writer-runs/probe/workspace"
        try fm.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let nativeBinary = NSHomeDirectory() + "/.local/bin/devin"
        let relaySource = NSHomeDirectory() + "/projects/fusion-codex-relay"
        let profile = try ProfileBuilder.devinProfile(home: root, model: "fusion-gpt-6-astra-high-sidekick-swe-2-medium")
        let wrapper = root + "/writer-runs/probe/reuse-fusion"
        let wrapperSource = """
        #!/usr/bin/python3
        import os,sys
        sys.path.insert(0,sys.argv[1])
        from fusion_relay import launcher as l
        from fusion_relay.identity import PrivateDirectory
        with PrivateDirectory(l.DATA_DIR) as private:
            conn=l._verified_conn(l._env_port(),private)
            conn.close()
            token=l._read_token(private)
        endpoint=l._endpoint(l._env_port())
        env=dict(os.environ,WINDSURF_API_SERVER_URL=endpoint+'/t/'+token)
        os.execve(sys.argv[2],[sys.argv[2],*sys.argv[3:]],env)
        """
        try wrapperSource.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper)
        let sb = profile + "/isolation.sb"
        try ProfileBuilder.writerSandboxProfile(workshopHome: root, worktree: workspace, profile: profile,
            token: root + "/writer-runs/probe/token", destination: sb)
        let tmp = root + "/writer-runs/probe/tmp"
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var env = ProfileBuilder.strippedEnv(profile: profile)
        env["TMPDIR"] = tmp
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        let db = profile + "/data/devin/cli/sessions.db"
        try fm.createDirectory(atPath: profile + "/data/devin/cli", withIntermediateDirectories: true)
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        create.arguments = [db, "PRAGMA user_version=0;"]
        create.standardOutput = FileHandle.nullDevice
        create.standardError = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        XCTAssertEqual(create.terminationStatus, 0)
        let transport = try ProcessACPTransport(argv: ["/usr/bin/sandbox-exec", "-f", sb, "/usr/bin/python3", wrapper, relaySource, nativeBinary,
            "--config", profile + "/config/devin/config.json", "--permission-mode", "accept-edits", "acp"], env: env, cwd: workspace)
        defer { transport.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { transport.terminate() }
        let client = ACPClient(transport: transport)
        _ = try await client.call("initialize", params: .object(["protocolVersion": .number(1), "clientCapabilities": .object([:]), "clientInfo": .object(["name": .string("workshop-qualification"), "version": .string("1")])]))
        let created = try await client.call("session/new", params: .object(["cwd": .string(workspace), "mcpServers": .array([])]))
        let sessionCreated = created["sessionId"]?.stringValue != nil
        try await Task.sleep(for: .seconds(2))
        await client.close()
        let stateExists = fm.fileExists(atPath: db)
        let cannotOpen = transport.stderrText.contains("CannotOpen")
        var integrity = ""
        var integrityStatus: Int32 = -1
        if stateExists {
            let check = Process(); let out = Pipe()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            check.arguments = ["-readonly", db, "PRAGMA integrity_check;"]
            check.standardOutput = out; check.standardError = FileHandle.nullDevice
            try check.run()
            integrity = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            check.waitUntilExit()
            integrityStatus = check.terminationStatus
        }
        print("NATIVE_DBONLY " + String(decoding: try JSONSerialization.data(withJSONObject: ["session_created": sessionCreated, "session_database_exists": stateExists, "integrity_ok": integrityStatus == 0 && integrity == "ok", "stderr_cannot_open": cannotOpen], options: [.sortedKeys]), as: UTF8.self))
        XCTAssertTrue(sessionCreated)
        XCTAssertTrue(stateExists)
        XCTAssertEqual(integrityStatus, 0)
        XCTAssertEqual(integrity, "ok")
        try assertNativePersistence(profile: profile)
    }
}
