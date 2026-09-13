import Foundation
import WorkshopCore
import WorkshopIPC

/// Shared client state for all windows (T34-lite).
@MainActor
public final class AppState: ObservableObject {
    @Published public var tasks: [WorkshopTask] = []
    @Published public var selectedTaskID: TaskID? {
        didSet { Task { await loadSelectedTask() } }
    }
    @Published public var detail: TaskDetail?
    @Published public var messages: [Message] = []
    @Published public var engineers: [AdapterProbe] = []
    @Published public var artifacts: [Artifact] = []
    @Published public var usageRows: [UsageSampleRecord] = []
    @Published public var proposals: [Proposal] = []
    @Published public var reports: [Report] = []
    @Published public var decisions: [Decision] = []

    /// WORKSHOP_HOME for resolving artifact paths (previews read local files).
    public var workshopHome: String {
        ProcessInfo.processInfo.environment["WORKSHOP_HOME"]
            ?? NSHomeDirectory() + "/Library/Application Support/Workshop"
    }
    @Published public var serviceUnavailable = false
    /// Incremented by menu commands; views focus the matching field.
    @Published public var composerFocusRequest = 0
    @Published public var searchFocusRequest = 0
    /// Older message pages exist beyond the loaded window (T31).
    @Published public var hasEarlierMessages = false
    /// Cmd-K / sidebar search results (workshop.search, §14.1).
    @Published public var searchResults: [AppSearchHit] = []
    /// "Recovered: N interrupted turns, M unresolved operations" (§14.1).
    @Published public var recoveryBanner: String?
    /// Latest workshop.diagnostics payload for the Diagnostics view.
    @Published public var diagnosticsJSON: String = ""
    /// Engineer raw id → capacity summary line for cards/rows (§10).
    @Published public var capacityLines: [String: String] = [:]
    /// Engineers whose bucket is limited or critical (task-row indicator).
    @Published public var capacityAlerts: Set<String> = []
    /// Notification seqs already handled — at-least-once dedupe (§8.5).
    private var seenEventSeqs: Set<Int64> = []

    public let client = WorkshopClient()
    private var notificationTask: Task<Void, Never>?
    private var subscribed = false

    public init() {}

    /// Connect to the daemon, launching it if needed.
    public func bootstrap() async {
        if (try? await client.connect()) != nil {
            await connected()
            return
        }
        launchDaemonIfPossible()
        // Wait up to 5 s for the socket.
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if (try? await client.connect()) != nil {
                await connected()
                return
            }
        }
        serviceUnavailable = true
    }

    private func connected() async {
        serviceUnavailable = false
        await refresh()
        // Dev hook: WORKSHOP_SELECT_TASK selects a task by id or title.
        if let want = ProcessInfo.processInfo.environment["WORKSHOP_SELECT_TASK"],
           !want.isEmpty,
           let match = tasks.first(where: {
               $0.id.rawValue == want || $0.title.localizedCaseInsensitiveContains(want)
           }) {
            selectedTaskID = match.id
            await loadSelectedTask()
        } else if selectedTaskID == nil {
            selectedTaskID = tasks.last?.id
            await loadSelectedTask()
        }
        if !subscribed {
            subscribed = true
            startNotifications()
        }
    }

    private func launchDaemonIfPossible() {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let p = env["WORKSHOP_DAEMON_PATH"], !p.isEmpty { candidates.append(p) }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("workshop-daemon").path)
            // Dev mode: walk up from the executable to find .build/debug/workshop-daemon.
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent(".build/debug/workshop-daemon").path
                candidates.append(candidate)
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    candidates.append(dir.appendingPathComponent(".build/debug/workshop-daemon").path)
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            try? process.run()
            return
        }
    }

    public func refresh() async {
        tasks = (try? await client.call(WorkshopProtocol.listTasks,
                                        as: [WorkshopTask].self)) ?? tasks
        engineers = (try? await client.call(WorkshopProtocol.listEngineers,
                                            as: [AdapterProbe].self)) ?? engineers
        await loadSelectedTask()
    }

    public func loadSelectedTask() async {
        guard let id = selectedTaskID else { detail = nil; messages = []; return }
        detail = try? await client.call(WorkshopProtocol.getTask,
                                        params: .object(["task_id": .string(id.rawValue)]),
                                        as: TaskDetail.self)
        // Newest page (T31); "Load earlier" pages backwards from first seq.
        if let page = try? await client.call(WorkshopProtocol.readMessagePage,
            params: .object(["task_id": .string(id.rawValue)]),
            as: [Message].self) {
            messages = page
            hasEarlierMessages = (page.first?.seq ?? 1) > 1
        }
        recoveryBanner = try? await client.call(
            WorkshopProtocol.recoverySummary,
            params: .object(["task_id": .string(id.rawValue)]),
            as: String.self)
        await refreshCapacity()
        let taskParams: JSONValue = .object(["task_id": .string(id.rawValue)])
        artifacts = (try? await client.call(WorkshopProtocol.listArtifacts,
                                            params: taskParams,
                                            as: [Artifact].self)) ?? []
        usageRows = (try? await client.call(WorkshopProtocol.listUsage,
                                            params: taskParams,
                                            as: [UsageSampleRecord].self)) ?? []
        proposals = (try? await client.call(WorkshopProtocol.listProposals,
                                            params: taskParams,
                                            as: [Proposal].self)) ?? []
        reports = (try? await client.call(WorkshopProtocol.listReports,
                                          params: taskParams,
                                          as: [Report].self)) ?? []
        decisions = (try? await client.call(WorkshopProtocol.listDecisions,
                                            params: taskParams,
                                            as: [Decision].self)) ?? []
    }

    private func startNotifications() {
        notificationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.makeNotificationStream()
            _ = try? await self.client.call(WorkshopProtocol.subscribe,
                                            params: .object(["after_seq": .number(0)]))
            for await notification in stream {
                if notification.method == WorkshopProtocol.eventNotification {
                    await self.handleEvent(notification.params)
                }
            }
        }
    }

    private func handleEvent(_ params: JSONValue?) async {
        // At-least-once delivery: dedupe by outbox seq (§8.5).
        if let seq = params?["seq"]?.intValue {
            if seenEventSeqs.contains(seq) { return }
            seenEventSeqs.insert(seq)
            if seenEventSeqs.count > 10_000 {
                seenEventSeqs = Set(seenEventSeqs.sorted().suffix(5_000))
            }
        }
        tasks = (try? await client.call(WorkshopProtocol.listTasks,
                                        as: [WorkshopTask].self)) ?? tasks
        guard let id = selectedTaskID,
              params?["task_id"]?.stringValue == id.rawValue else { return }
        await loadSelectedTask()
    }

    /// Create a task; returns the receipt.
    @discardableResult
    public func createTask(title: String, objective: String, phase: TaskPhase,
                           idempotencyKey: String? = nil) async -> CreateTaskReceipt? {
        let request = CreateTaskRequest(
            idempotencyKey: idempotencyKey ?? UUID().uuidString,
            title: title, objective: objective, phase: phase,
            participants: EngineerID.allCases)
        guard let params = try? JSONValue.from(request),
              let receipt = try? await client.call(WorkshopProtocol.createTask,
                                                   params: params,
                                                   as: CreateTaskReceipt.self) else {
            return nil
        }
        await refresh()
        selectedTaskID = receipt.taskID
        return receipt
    }

    public func postMessage(_ body: String) async {
        guard let id = selectedTaskID else { return }
        _ = try? await client.call(
            WorkshopProtocol.postMessage,
            params: .object(["task_id": .string(id.rawValue), "body": .string(body)]))
        await loadSelectedTask()
    }

    // MARK: - Phase 3 user actions

    private func taskAction(_ method: String,
                            extra: [String: JSONValue] = [:]) async -> String? {
        guard let id = selectedTaskID else { return nil }
        var params: [String: JSONValue] = ["task_id": .string(id.rawValue)]
        for (k, v) in extra { params[k] = v }
        do {
            _ = try await client.call(method, params: .object(params),
                                      as: JSONValue.self)
            await loadSelectedTask()
            return nil
        } catch {
            await loadSelectedTask()
            return error.localizedDescription
        }
    }

    /// Last action error, surfaced in the Proposals tab / header menu.
    @Published public var lastActionError: String?

    public func pauseTask() async { lastActionError = await taskAction(WorkshopProtocol.pauseTask) }
    public func resumeTask() async { lastActionError = await taskAction(WorkshopProtocol.resumeTask) }
    public func cancelTask() async { lastActionError = await taskAction(WorkshopProtocol.cancelTask) }
    public func acceptTask() async { lastActionError = await taskAction(WorkshopProtocol.acceptTask) }
    public func convertToResearch() async {
        lastActionError = await taskAction(WorkshopProtocol.convertToResearch)
    }

    public func approveArchitecture(reportRevision: Int, scope: String? = nil) async {
        var extra: [String: JSONValue] = ["report_revision": .number(Double(reportRevision))]
        if let scope { extra["scope"] = .string(scope) }
        lastActionError = await taskAction(WorkshopProtocol.approveArchitecture,
                                           extra: extra)
    }

    public func requestChanges(reportRevision: Int, comment: String) async {
        lastActionError = await taskAction(WorkshopProtocol.requestChanges, extra: [
            "report_revision": .number(Double(reportRevision)),
            "comment": .string(comment),
        ])
    }

    public func chooseAlternative(reportRevision: Int, index: Int) async {
        lastActionError = await taskAction(WorkshopProtocol.chooseAlternative, extra: [
            "report_revision": .number(Double(reportRevision)),
            "alternative_index": .number(Double(index)),
        ])
    }

    // MARK: - Phase 4: paging, search, export, diagnostics, capacity

    /// App-local mirror of the service's SearchHit (app target has no
    /// dependency on WorkshopService).
    public struct AppSearchHit: Codable, Sendable, Identifiable {
        public var id: String { taskID.rawValue + kind + snippet }
        public var taskID: TaskID
        public var kind: String
        public var snippet: String
    }

    /// Prepend the page before the current first message; keeps ≤2000 in
    /// memory by trimming the newest tail (T31).
    public func loadEarlierMessages() async {
        guard let id = selectedTaskID, let first = messages.first else { return }
        guard let older = try? await client.call(
            WorkshopProtocol.readMessagePage,
            params: .object(["task_id": .string(id.rawValue),
                             "before_seq": .number(Double(first.seq))]),
            as: [Message].self), !older.isEmpty else {
            hasEarlierMessages = false
            return
        }
        messages = older + messages
        if messages.count > 2_000 { messages = Array(messages.prefix(2_000)) }
        hasEarlierMessages = (older.first?.seq ?? 1) > 1
    }

    /// workshop.search over messages/decisions/artifacts (§14.1, Cmd-K).
    public func runSearch(_ query: String) async {
        guard !query.isEmpty else { searchResults = []; return }
        searchResults = (try? await client.call(WorkshopProtocol.search,
            params: .object(["query": .string(query), "limit": .number(50)]),
            as: [AppSearchHit].self)) ?? []
    }

    /// workshop.exportTask into a user-chosen directory (§14.1).
    public func exportSelectedTask(destDir: String) async {
        guard let id = selectedTaskID else { return }
        lastActionError = await taskAction(WorkshopProtocol.exportTask,
                                           extra: ["dest_dir": .string(destDir)])
    }

    /// workshop.diagnostics for the Diagnostics view (§14.5).
    public func refreshDiagnostics() async {
        if let json = try? await client.call(WorkshopProtocol.diagnostics,
                                             as: JSONValue.self),
           let data = try? JSONEncoder().encode(json),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            diagnosticsJSON = String(decoding: pretty, as: UTF8.self)
        }
    }

    /// workshop_get_capacity tool (callable as user) → per-engineer lines.
    public func refreshCapacity() async {
        guard let cap = try? await client.call("workshop_get_capacity",
                                               as: JSONValue.self) else { return }
        var lines: [String: String] = [:]
        var alerts: Set<String> = []
        for engineer in EngineerID.allCases {
            guard let info = cap[engineer.rawValue] else { continue }
            let availability = info["availability"]?.stringValue ?? "unknown"
            let observed = info["observed_at"]?.stringValue
            switch availability {
            case "unknown":
                lines[engineer.rawValue] = observed == nil
                    ? "unknown — not measured" : "unknown — measured \(observed!)"
            case "limited":
                lines[engineer.rawValue] = "limited since \(observed ?? "now")"
                alerts.insert(engineer.rawValue)
            case "critical":
                lines[engineer.rawValue] = "critical since \(observed ?? "now")"
                alerts.insert(engineer.rawValue)
            default:
                let remaining = info["remaining"]?.stringValue ?? "?"
                lines[engineer.rawValue] =
                    "\(remaining) left — measured \(observed ?? "recently")"
            }
        }
        capacityLines = lines
        capacityAlerts = alerts
    }

    /// True when the selected task's owner bucket is limited/critical — the
    /// compact impact indicator on the task row/header (§10).
    public func selectedTaskCapacityAlert() -> String? {
        guard let detail else { return nil }
        for sub in detail.subtasks {
            if let owner = sub.ownerID,
               capacityAlerts.contains(owner.rawValue) {
                return "\(owner.displayName) capacity \(capacityLines[owner.rawValue] ?? "limited")"
            }
        }
        return nil
    }
}
