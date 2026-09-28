import Foundation
import WorkshopCore
import WorkshopService

/// Lane-selecting adapter (decision D-b): runs an engineer's turns on the
/// native lane while it works and falls back to the managed runtime lane
/// after classified native startup failures — `auth` immediately, other
/// classes after two failures on the same task (the coalescer's backoff
/// spaces the retries). The active lane is reported through `laneObserver`
/// so the service can record lane provenance on messages.
public final class LaneSelectingAdapter: CapabilityAwareAdapter, @unchecked Sendable {
    /// Prefix on managed-lane nativeSessionIDs so sendTurn/cancelTurn route.
    public static let managedPrefix = "managed:"

    public let engineer: EngineerID
    private let native: EngineerAdapter?
    private let managed: EngineerAdapter?
    private let laneObserver: @Sendable (TaskID, EngineerID, String) async -> Void
    private let lock = NSLock()
    /// Consecutive native openTaskSession failures per task.
    private var nativeFailures: [TaskID: Int] = [:]
    /// Last resolved lane — drives capability reporting until the next open.
    private var resolvedLane: String
    /// Failure class that triggered the most recent managed fallback.
    private var lastFallbackClass: StartupFailureClass?
    /// When "managed", the native lane is skipped entirely (qualification runs).
    public var forcedLane: String? {
        get { lock.lock(); defer { lock.unlock() }; return _forcedLane }
        set { lock.lock(); _forcedLane = newValue; lock.unlock() }
    }
    private var _forcedLane: String?

    /// Capability-aware forwarding: DaemonRuntime injects the record lookup
    /// into each wrapped adapter through this setter.
    public var capabilityLookup: (@Sendable (QualificationIdentity) -> CapabilityRecord?)? {
        get { nil }
        set {
            (native as? CapabilityAwareAdapter)?.capabilityLookup = newValue
            (managed as? CapabilityAwareAdapter)?.capabilityLookup = newValue
        }
    }
    public var binaryDriftNotice: String? {
        get { nil }
        set {
            (native as? CapabilityAwareAdapter)?.binaryDriftNotice = newValue
            (managed as? CapabilityAwareAdapter)?.binaryDriftNotice = newValue
        }
    }
    public var qualificationIdentity: QualificationIdentity? { nil }
    public var qualificationBinaryPath: String? { nil }
    /// Drift/lookup apply per lane identity, not per wrapper.
    public var capabilitySubjects: [any CapabilityAwareAdapter] {
        [native, managed].compactMap { $0 as? CapabilityAwareAdapter }
    }

    public init(engineer: EngineerID, native: EngineerAdapter?,
                managed: EngineerAdapter?,
                laneObserver: @escaping @Sendable (TaskID, EngineerID, String) async -> Void) {
        self.engineer = engineer
        self.native = native
        self.managed = managed
        self.laneObserver = laneObserver
        self.resolvedLane = native == nil ? "managed" : "native"
    }

    /// The lane the last openTaskSession resolved to.
    private var activeLane: String {
        lock.lock(); defer { lock.unlock() }
        return resolvedLane
    }

    public var supportsIsolatedWorkspaceTurns: Bool {
        activeLane == "managed"
            ? (managed?.supportsIsolatedWorkspaceTurns ?? false)
            : (native?.supportsIsolatedWorkspaceTurns
               ?? managed?.supportsIsolatedWorkspaceTurns ?? false)
    }

    /// Either lane needing a fenced generation copy forces one.
    public var usesWorkspaceFilesystem: Bool {
        (native?.usesWorkspaceFilesystem ?? false)
            || (managed?.usesWorkspaceFilesystem ?? false)
    }

    public var modelSelection: String? {
        activeLane == "managed" ? managed?.modelSelection : native?.modelSelection
            ?? managed?.modelSelection
    }

    public func probe() async -> AdapterProbe {
        if let native {
            let probe = await native.probe()
            if probe.health.kind == .unavailable || probe.health.kind == .loginRequired,
               let managed {
                var fallback = await managed.probe()
                fallback.health = EngineerHealth(
                    fallback.health.kind,
                    detail: "managed lane: " + fallback.health.detail)
                return fallback
            }
            return probe
        }
        if let managed { return await managed.probe() }
        return AdapterProbe(engineer: engineer,
                            health: .unavailable("no lane configured"),
                            tested: false)
    }

    public func openTaskSession(binding: SessionBinding) async throws -> SessionRef {
        if let native, forcedLane != "managed" {
            // A managed lane ref is meaningless to the native lane; resume
            // natively fresh after a managed fallback.
            var nativeBinding = binding
            if nativeBinding.nativeSessionID?.hasPrefix(Self.managedPrefix) == true {
                nativeBinding.nativeSessionID = nil
            }
            do {
                let ref = try await native.openTaskSession(binding: nativeBinding)
                lock.lock()
                nativeFailures[binding.taskID] = 0
                resolvedLane = "native"
                lock.unlock()
                await laneObserver(binding.taskID, engineer, "native")
                return ref
            } catch {
                lock.lock()
                let priorFailures = nativeFailures[binding.taskID] ?? 0
                nativeFailures[binding.taskID] = priorFailures + 1
                lock.unlock()
                let klass = StartupFailureClass.classify(
                    workshopErrorDescription(error))
                guard let managed,
                      klass == .auth || priorFailures >= 2 else {
                    throw error
                }
                return try await openManaged(binding: binding, klass: klass)
            }
        }
        guard let managed else {
            throw WorkshopError.adapterUnavailable(engineer)
        }
        return try await openManaged(binding: binding, klass: nil)
    }

    private func openManaged(binding: SessionBinding,
                             klass: StartupFailureClass?) async throws -> SessionRef {
        var managedBinding = binding
        if managedBinding.nativeSessionID?.hasPrefix(Self.managedPrefix) == true {
            managedBinding.nativeSessionID =
                String(managedBinding.nativeSessionID!.dropFirst(Self.managedPrefix.count))
        } else {
            managedBinding.nativeSessionID = nil
        }
        var ref = try await managed!.openTaskSession(binding: managedBinding)
        ref.nativeSessionID = Self.managedPrefix + ref.nativeSessionID
        lock.lock()
        resolvedLane = "managed"
        lastFallbackClass = klass
        lock.unlock()
        await laneObserver(binding.taskID, engineer, "managed")
        return ref
    }

    public func sendTurn(ref: SessionRef, turnID: String, context: TurnContext,
                         deadline: Date) -> AsyncThrowingStream<AdapterEvent, Error> {
        let onManaged = ref.nativeSessionID.hasPrefix(Self.managedPrefix)
            || native == nil
        if onManaged, let managed {
            let stripped = SessionRef(
                engineer: engineer,
                nativeSessionID: ref.nativeSessionID.hasPrefix(Self.managedPrefix)
                    ? String(ref.nativeSessionID.dropFirst(Self.managedPrefix.count))
                    : ref.nativeSessionID)
            let inner = managed.sendTurn(ref: stripped, turnID: turnID,
                                       context: context, deadline: deadline)
            lock.lock()
            let fellBack = native != nil
            let klass = lastFallbackClass
            lock.unlock()
            return AsyncThrowingStream { continuation in
                Task {
                    if fellBack {
                        let cause = klass.map { " (\($0.rawValue))" } ?? ""
                        continuation.yield(.uncertain(
                            "Native lane unavailable\(cause); this turn runs "
                            + "on the managed lane without native tooling"))
                    }
                    do {
                        for try await event in inner { continuation.yield(event) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        return native!.sendTurn(ref: ref, turnID: turnID, context: context,
                                deadline: deadline)
    }

    @discardableResult
    public func cancelTurn(ref: SessionRef, turnID: String) async -> Bool {
        if ref.nativeSessionID.hasPrefix(Self.managedPrefix), let managed {
            let stripped = SessionRef(
                engineer: engineer,
                nativeSessionID: String(ref.nativeSessionID.dropFirst(Self.managedPrefix.count)))
            return await managed.cancelTurn(ref: stripped, turnID: turnID)
        }
        return await native?.cancelTurn(ref: ref, turnID: turnID) ?? true
    }
}
