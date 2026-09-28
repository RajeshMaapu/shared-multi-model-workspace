import Foundation
import WorkshopCore
import WorkshopStore
import WorkshopService
import WorkshopAdapters

/// `workshop-daemon qualify` (G-E5): runs the isolated-writer recipe against a
/// TEMPORARY Workshop home using the real adapter for one engineer (all other
/// engineers fake), then records the outcome in `<home>/config/capabilities.json`.
/// The live `<home>/db` is never opened. Exit code 0 only when qualified.
public enum QualificationRunner {
    /// The exact recipe used by .build/phase2-smoke.
    public static let recipeObjective = """
        Create a file hello.txt containing exactly workshop-phase2-ok, \
        run `cat hello.txt`, then call workshop_post_message with \
        'files ready' and workshop_report_result with summary 'phase2 smoke \
        ok' and validation [{"check":"cat hello.txt","result":"workshop-phase2-ok"}].
        """
    public static let expectedFileName = "hello.txt"
    public static let expectedFileContent = "workshop-phase2-ok"

    public static let usage = """
        usage: workshop-daemon qualify --engineer <devin|kimi|deepseek> \
        [--lane native|managed] [--home <WORKSHOP_HOME>] [--evidence-dir <dir>]

        Runs the isolated-writer recipe in a temporary home with the real \
        adapter for <engineer> (other engineers fake), writes the evidence \
        (task dump + notes) to --evidence-dir (default \
        <home>/config/qualification/<engineer>-<lane>-<ts>), and records the \
        result in <home>/config/capabilities.json. Exits 0 only when the \
        recipe passed. The live database is never opened.
        """

    public struct Options {
        public var engineer: EngineerID = .devin
        public var lane: String = "native"
        public var home: String = NSHomeDirectory()
            + "/Library/Application Support/Workshop"
        public var evidenceDir: String?
        /// Qualify deadline; the smoke recipe should finish in well under a
        /// minute live. Tests pass a much smaller value.
        public var timeoutSeconds: TimeInterval = 480
        /// After a successful recipe, run ONE more turn on the same task:
        /// ask the engineer what it produced and record the reply as
        /// `continuity: pass|fail — <reply>` on the capability record.
        public var continuityCheck = false
        /// Preserve the temporary qualification home on exit (failure
        /// forensics) and print its path instead of deleting it.
        public var keepHome = false
    }

    public static func parse(_ args: [String]) -> Options? {
        var options = Options()
        var index = 1 // args[0] is the executable; caller passes all args with [1]=="qualify"
        index += 1    // skip "qualify"
        var sawEngineer = false
        while index < args.count {
            let flag = args[index]
            let value = index + 1 < args.count ? args[index + 1] : nil
            switch flag {
            case "--engineer":
                guard let value, let id = EngineerID(rawValue: value)
                else { return nil }
                options.engineer = id
                sawEngineer = true
            case "--lane":
                guard let value, ["native", "managed"].contains(value)
                else { return nil }
                options.lane = value
            case "--home":
                guard let value else { return nil }
                options.home = (value as NSString).expandingTildeInPath
            case "--evidence-dir":
                guard let value else { return nil }
                options.evidenceDir =
                    (value as NSString).expandingTildeInPath
            case "--continuity-check":
                options.continuityCheck = true
                index += 1
                continue
            case "--keep-home":
                options.keepHome = true
                index += 1
                continue
            default:
                return nil
            }
            index += 2
        }
        return sawEngineer ? options : nil
    }

    /// Returns the process exit code: 0 qualified, 1 not qualified,
    /// 2 setup/usage failure.
    public static func run(_ options: Options,
                           env: [String: String] =
                               ProcessInfo.processInfo.environment,
                           fakeConfigurator: (@Sendable (FakeAdapter) -> Void)? = nil,
                           afterRecord: (@Sendable () -> Void)? = nil)
        async -> Int32 {
        let fm = FileManager.default
        let configSource = options.home + "/config/engineers.json"
        guard fm.fileExists(atPath: configSource) else {
            FileHandle.standardError.write(Data(
                "qualify: \(configSource) not found\n".utf8))
            return 2
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let evidenceDir = options.evidenceDir ?? options.home
            + "/config/qualification/\(options.engineer.rawValue)-"
            + "\(options.lane)-\(stamp)"
        // Short paths: the UDS socket ceiling is ~100 chars.
        let stamp8 = UUID().uuidString.lowercased().prefix(8)
        let tempHome = "/tmp/wq-\(stamp8)"
        let tempRuntime = "/tmp/wqr-\(stamp8)"
        do {
            try fm.createDirectory(atPath: tempHome + "/config",
                                   withIntermediateDirectories: true)
            try fm.copyItem(atPath: configSource,
                            toPath: tempHome + "/config/engineers.json")
            try fm.createDirectory(atPath: evidenceDir,
                                   withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data(
                "qualify: setup failed: \(error.localizedDescription)\n".utf8))
            return 2
        }
        defer {
            if !options.keepHome { try? fm.removeItem(atPath: tempHome) }
        }

        var qualifyEnv = env
        // With a fakeConfigurator the target itself is a fake (unit tests);
        // otherwise it runs live while every other engineer is fake.
        qualifyEnv["WORKSHOP_ADAPTERS"] = fakeConfigurator != nil
            ? "fake"
            : "mixed:" + EngineerID.allCases.map {
                "\($0.rawValue)=\($0 == options.engineer ? "live" : "fake")"
            }.joined(separator: ",")
        qualifyEnv["WORKSHOP_HOME"] = tempHome
        qualifyEnv["WORKSHOP_RUNTIME_DIR"] = tempRuntime

        let runtime: DaemonRuntime
        do {
            runtime = try DaemonRuntime(home: tempHome, runtimeDir: tempRuntime,
                                        env: qualifyEnv,
                                        fakeConfigurator: fakeConfigurator)
        } catch {
            FileHandle.standardError.write(Data(
                ("qualify: runtime setup failed: "
                 + "\(error.localizedDescription)\n").utf8))
            return 2
        }
        let service = runtime.service
        // Scripted fakes reach the service through toolRunner.
        for adapter in runtime.adapters {
            (adapter as? FakeAdapter)?.toolRunner = { name, args, principal in
                try await service.callTool(name, args: args, principal: principal)
            }
        }
        do { try await runtime.start() } catch {
            FileHandle.standardError.write(Data(
                ("qualify: daemon start failed: "
                 + "\(error.localizedDescription)\n").utf8))
            return 2
        }
        // Bypass the qualification gate for the lane under test — the whole
        // point is to produce that record. start() re-applies the (empty)
        // capability store, so this must run afterwards.
        if let aware = runtime.adapters.first(where: {
            $0.engineer == options.engineer }) as? CapabilityAwareAdapter {
            for subject in aware.capabilitySubjects
                where subject.qualificationIdentity?.lane == options.lane {
                subject.capabilityLookup = { identity in
                    CapabilityRecord(engineer: identity.engineer,
                                     lane: identity.lane,
                                     capability: CapabilityStore.isolatedWriter,
                                     model: identity.model,
                                     qualified: true, probedAt: Date(),
                                     notes: "qualification run in progress")
                }
            }
        }
        if options.lane == "managed",
           let lane = runtime.adapters.first(where: {
               $0.engineer == options.engineer }) as? LaneSelectingAdapter {
            lane.forcedLane = "managed"
        }
        var binaryPath: String?
        var identityModel: String?
        if let aware = runtime.adapters.first(where: {
            $0.engineer == options.engineer }) as? CapabilityAwareAdapter,
           let subject = aware.capabilitySubjects.first(where: {
               $0.qualificationIdentity?.lane == options.lane }) {
            binaryPath = subject.qualificationBinaryPath
            identityModel = subject.qualificationIdentity?.model
        }
        let outcome = await runRecipe(options: options, service: service)
        // Evidence: task dump + permission-rejection scan + notes.
        var notes = outcome.notes
        let rejections = permissionRejections(under: tempHome)
        if rejections > 0 {
            notes.append("\(rejections) harness permission rejection(s)")
        }
        if let detail = try? await service.getTask(outcome.taskID),
           let data = try? JSONEncoder().encode(detail) {
            try? data.write(to: URL(fileURLWithPath:
                evidenceDir + "/task-detail.json"))
        }
        try? Data(notes.joined(separator: "\n").utf8)
            .write(to: URL(fileURLWithPath: evidenceDir + "/notes.txt"))

        // The record and the verdict line are the point of the command —
        // write both BEFORE shutting the temp runtime down (an earlier
        // version shutdown first and a slow teardown ate both).
        let qualified = outcome.verified && outcome.helloOK && rejections == 0
        // --continuity-check: one more turn on the same task asking the
        // engineer what it produced — proves the session can continue a
        // handed-over subtask without losing context.
        var continuityNote: String?
        if options.continuityCheck, qualified {
            let reply = await continuityReply(options: options,
                                              service: service,
                                              taskID: outcome.taskID)
            // The model may have reported more than once (3.7 deepseek
            // answered "revision 2" correctly after a second report call)
            // — continuity is proven by naming the file and ANY revision,
            // not the literal first one.
            let pass = reply.contains(expectedFileName)
                && reply.range(of: #"revision +\d"#, options: .regularExpression)
                    != nil
            continuityNote = "continuity: \(pass ? "pass" : "fail") — "
                + String(reply.prefix(200))
            notes.append(continuityNote!)
            try? Data(notes.joined(separator: "\n").utf8)
                .write(to: URL(fileURLWithPath: evidenceDir + "/notes.txt"))
        }
        let store = CapabilityStore(path: options.home
            + "/config/capabilities.json")
        try? store.record(CapabilityRecord(
            engineer: options.engineer, lane: options.lane,
            capability: CapabilityStore.isolatedWriter,
            model: outcome.model ?? identityModel,
            binarySHA256: binaryPath.flatMap(CapabilityStore.sha256(file:)),
            qualified: qualified, probedAt: Date(),
            evidencePath: evidenceDir,
            notes: continuityNote
                ?? (qualified ? nil : notes.joined(separator: "; "))))
        FileHandle.standardOutput.write(Data(
            ("qualify \(options.engineer.rawValue)/\(options.lane): "
             + (qualified ? "qualified" : "NOT qualified")
             + " (evidence: \(evidenceDir))"
             + (options.keepHome ? "; home: \(tempHome)" : "")
             + "\n").utf8))
        afterRecord?()
        await runtime.shutdown()
        return qualified ? 0 : 1
    }

    private struct RecipeOutcome {
        var taskID: TaskID
        var verified = false      // task reached verifying (devin lane)
        var helloOK = false       // sealed snapshot carries hello.txt
        var model: String?
        var notes: [String] = []
    }

    private static func runRecipe(options: Options,
                                  service: CollaborationService)
        async -> RecipeOutcome {
        let isPeer = options.engineer != .devin
        var notes: [String] = []
        let request = CreateTaskRequest(
            schemaVersion: 2,
            idempotencyKey: "qualify-" + UUID().uuidString.lowercased(),
            title: "Writer qualification: \(options.engineer.rawValue)/\(options.lane)",
            objective: recipeObjective,
            phase: .execution,
            participants: isPeer ? [options.engineer] : [.devin],
            collaborationMode: isPeer ? .requestedPeers : .ownerOnly)
        let taskID: TaskID
        do {
            taskID = try await service.createTask(request,
                                                  principal: .user).taskID
        } catch {
            return RecipeOutcome(taskID: TaskID("qualify-none"),
                                 notes: ["createTask failed: "
                                     + workshopErrorDescription(error)])
        }
        if isPeer {
            // Writer proof needs an authoritative turn, and only a dispatch
            // claim takes the task queued → working. Let Devin's dispatch
            // claim run first, then hand the subtask to the engineer under
            // test via the user-authority reassign path. The fake Devin turn
            // ends in seconds; a slow one is cancelled by reassignSubtask.
            let handoverDeadline = Date().addingTimeInterval(120)
            var assigned = false
            while !assigned, Date() < handoverDeadline {
                if let detail = try? await service.getTask(taskID),
                   let sub = detail.subtasks.first,
                   detail.task.state == .working,
                   sub.ownerID == .devin {
                    do {
                        try await service.reassignSubtask(
                            subtaskID: sub.id, newOwner: options.engineer,
                            principal: .user, permitClosedHandover: true)
                        assigned = true
                    } catch {
                        // Writer generation still open or CAS race — retry.
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            guard assigned else {
                return RecipeOutcome(taskID: taskID,
                                     notes: ["subtask handover to "
                                         + options.engineer.rawValue
                                         + " never completed"])
            }
        }
        let deadline = Date().addingTimeInterval(options.timeoutSeconds)
        // Proof the owner's turn completed: task reached verifying, or its
        // subtask is in review with a committed result revision. A trailing
        // wakeup can legitimately bounce verifying → working (the next
        // execution turn marks working at start), so a transient verifying
        // window must not fail the recipe.
        func ownerVerified(_ detail: TaskDetail) -> Bool {
            if detail.task.state == .verifying { return true }
            guard let sub = detail.subtasks.first(
                where: { $0.ownerID == options.engineer }),
                  sub.state == .review else { return false }
            return (detail.subtaskResults?[sub.id.rawValue]?.resultRevision ?? 0) > 0
        }
        var done = false
        while Date() < deadline && !done {
            // A sealed writer generation (not a review copy) plus the owner
            // result; the two are not written in one transaction.
            let snapshotReady = (try? await service.writerSnapshotPath(
                taskID: taskID, engineer: options.engineer,
                sealedOnly: true)) != nil
            if snapshotReady,
               let detail = try? await service.getTask(taskID),
               ownerVerified(detail) {
                done = true
            }
            if !done { try? await Task.sleep(for: .seconds(1)) }
        }
        var outcome = RecipeOutcome(taskID: taskID, notes: notes)
        if let detail = try? await service.getTask(taskID) {
            outcome.verified = ownerVerified(detail)
        }
        if let snapshot = try? await service.writerSnapshotPath(
            taskID: taskID, engineer: options.engineer, sealedOnly: true) {
            let hello = snapshot + "/" + expectedFileName
            outcome.helloOK = (try? String(contentsOfFile: hello))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                == expectedFileContent
            if !outcome.helloOK {
                outcome.notes.append("snapshot missing \(expectedFileName) "
                    + "with expected content")
            }
        } else {
            outcome.notes.append("no sealed writer generation for "
                + options.engineer.rawValue)
        }
        if !done { outcome.notes.append("qualification timed out") }
        return outcome
    }

    /// `--continuity-check`: post the memory question as the user, wait for
    /// the engineer's reply message, and return it verbatim.
    private static func continuityReply(options: Options,
                                        service: CollaborationService,
                                        taskID: TaskID) async -> String {
        // Baseline seq must ignore streaming placeholders: they carry a
        // provisional seq ≥ 1e9, so a mid-flight turn during baseline
        // capture would set `before` beyond every real seq and the reply
        // could never match (3.7 kimi run: reply seq 21 committed 20 s
        // after the question yet reported "no reply").
        let before = ((try? await service.readMessages(
            taskID, afterSeq: 0, limit: 500)) ?? [])
            .filter { $0.seq < WorkshopRepository.provisionalSeqBase }
            .map(\.seq).max() ?? 0
        do {
            _ = try await service.postMessage(
                taskID: taskID,
                body: "@\(options.engineer.rawValue) In one sentence: "
                    + "what file did you create and what was your "
                    + "result revision?",
                principal: .user)
        } catch {
            return "post failed: \(workshopErrorDescription(error))"
        }
        let bound = min(options.timeoutSeconds, 120)
        let deadline = Date().addingTimeInterval(bound)
        while Date() < deadline {
            if let messages = try? await service.readMessages(
                taskID, afterSeq: before, limit: 500),
               let reply = messages.last(where: {
                   $0.author.engineerID == options.engineer
                       && $0.kind == .text
                       // The in-flight turn's streamed placeholder is a
                       // `text` row too — committed and non-empty only, or
                       // an early poll returns "" (3.6 kimi run).
                       && $0.deliveryState == .committed
                       && !$0.body.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty
               }) {
                return reply.body
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return "<no reply within \(Int(bound))s>"
    }

    /// Count harness permission rejections anywhere under the temp home —
    /// the qualification must complete with zero interactive denials.
    static func permissionRejections(under root: String) -> Int {
        guard let enumerator = FileManager.default
            .enumerator(atPath: root) else { return 0 }
        var count = 0
        for case let path as String in enumerator {
            let full = root + "/" + path
            guard let attrs = try? FileManager.default
                .attributesOfItem(atPath: full),
                (attrs[.size] as? Int ?? 0) < 1_000_000,
                let text = try? String(contentsOfFile: full) else { continue }
            var rest = text[...]
            while let range = rest.range(
                of: "User rejected tool permission") {
                count += 1
                rest = rest[range.upperBound...]
            }
        }
        return count
    }
}
