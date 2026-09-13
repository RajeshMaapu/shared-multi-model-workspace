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

    /// WORKSHOP_HOME for resolving artifact paths (previews read local files).
    public var workshopHome: String {
        ProcessInfo.processInfo.environment["WORKSHOP_HOME"]
            ?? NSHomeDirectory() + "/Library/Application Support/Workshop"
    }
    @Published public var serviceUnavailable = false
    /// Incremented by menu commands; views focus the matching field.
    @Published public var composerFocusRequest = 0
    @Published public var searchFocusRequest = 0

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
        messages = (try? await client.call(WorkshopProtocol.readMessages,
                                           params: .object(["task_id": .string(id.rawValue)]),
                                           as: [Message].self)) ?? messages
        let taskParams: JSONValue = .object(["task_id": .string(id.rawValue)])
        artifacts = (try? await client.call(WorkshopProtocol.listArtifacts,
                                            params: taskParams,
                                            as: [Artifact].self)) ?? []
        usageRows = (try? await client.call(WorkshopProtocol.listUsage,
                                            params: taskParams,
                                            as: [UsageSampleRecord].self)) ?? []
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
}
