import SwiftUI
import AppKit
import WorkshopCore

@main
struct WorkshopApp: App {
    @StateObject private var state = AppState()
    @AppStorage("sendOnEnter") private var sendOnEnter = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear { applyEnvironmentHooks() }
                .task { await startUp() }
        }
        .defaultSize(width: 1440, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { state.composerFocusRequest += 1 }
                    .keyboardShortcut("n")
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("Search") { state.searchFocusRequest += 1 }
                    .keyboardShortcut("k")
                Button("Diagnostics") { openWindow(id: "diagnostics") }
            }
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(state)
                .frame(minWidth: 640, minHeight: 480)
                .task { await state.refreshDiagnostics() }
        }

        Settings {
            Form {
                Toggle("Send messages with Return (Shift-Return for newline)",
                       isOn: $sendOnEnter)
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private func startUp() async {
        await state.bootstrap()
        applyDevFixtures()
        // Dev seed: WORKSHOP_SEED_TASK="title|||objective"
        if let seed = ProcessInfo.processInfo.environment["WORKSHOP_SEED_TASK"],
           !seed.isEmpty {
            let parts = seed.components(separatedBy: "|||")
            let title = parts.first ?? "Seeded task"
            let objective = parts.count > 1 ? parts[1] : title
            await state.createTask(title: title, objective: objective, phase: .execution,
                                   idempotencyKey: "seed-" + seed)
        }
        scheduleScreenshotIfRequested()
    }

    private func applyEnvironmentHooks() {
        let env = ProcessInfo.processInfo.environment
        if let appearance = env["WORKSHOP_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let size = env["WORKSHOP_WINDOW_SIZE"] {
            let parts = size.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let window = NSApp.windows.first {
                        var frame = window.frame
                        frame.size = NSSize(width: parts[0], height: parts[1])
                        window.setFrame(frame, display: true)
                    }
                }
            }
        }
    }

    /// Dev fixtures for Phase 4 evidence screenshots — they only set
    /// view-model state; nothing is written to the daemon.
    ///   WORKSHOP_FAKE_CAPACITY="devin:critical since 09:00,kimi:limited since 09:12"
    ///   WORKSHOP_FAKE_BANNER="Recovered: 2 interrupted turns, 1 unresolved operations"
    ///   WORKSHOP_FAKE_SEARCH="kind|snippet" (repeatable via ;)
    ///   WORKSHOP_OPEN_DIAGNOSTICS=1 opens the Diagnostics window and the
    ///   screenshot captures it instead of the main window.
    private func applyDevFixtures() {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["WORKSHOP_FAKE_CAPACITY"], !spec.isEmpty {
            var lines: [String: String] = [:]
            var alerts: Set<String> = []
            for entry in spec.split(separator: ",") {
                let kv = entry.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = String(kv[0]), line = String(kv[1])
                lines[key] = line
                if line.hasPrefix("limited") || line.hasPrefix("critical") {
                    alerts.insert(key)
                }
            }
            state.capacityLines = lines
            state.capacityAlerts = alerts
        }
        if let banner = env["WORKSHOP_FAKE_BANNER"], !banner.isEmpty {
            state.recoveryBanner = banner
        }
        if let spec = env["WORKSHOP_FAKE_SEARCH"], !spec.isEmpty,
           let taskID = state.selectedTaskID {
            state.searchResults = spec.split(separator: ";").map { part in
                let kv = part.split(separator: "|", maxSplits: 1)
                return AppState.AppSearchHit(
                    taskID: taskID, kind: String(kv.first ?? "message"),
                    snippet: String(kv.count > 1 ? kv[1] : part))
            }
        }
        if env["WORKSHOP_OPEN_DIAGNOSTICS"] == "1" {
            openWindow(id: "diagnostics")
        }
    }

    /// WORKSHOP_SCREENSHOT_PATH: capture own main window after the fake reply streamed.
    private func scheduleScreenshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["WORKSHOP_SCREENSHOT_PATH"],
              !path.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(2500))
            // Wait until no message is still streaming (bounded).
            for _ in 0..<100 {
                if !state.messages.contains(where: { $0.deliveryState == .streaming }) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
            captureMainWindow(to: path)
            NSApp.terminate(nil)
        }
    }

    private func captureMainWindow(to path: String) {
        // When WORKSHOP_OPEN_CARD / WORKSHOP_OPEN_DIAGNOSTICS is set, capture
        // the popover/secondary window — it is not part of the main
        // contentView.
        let wantSecondary = ProcessInfo.processInfo
            .environment["WORKSHOP_OPEN_CARD"] != nil
            || ProcessInfo.processInfo
                .environment["WORKSHOP_OPEN_DIAGNOSTICS"] == "1"
        let window = wantSecondary ? (NSApp.windows.last ?? NSApp.windows.first)
                                   : NSApp.windows.first
        guard let window else { return }
        // Prefer rendering the view directly: CGWindowList capture returns a
        // blank image without screen-recording permission, which this dev
        // path should not require.
        if let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    return
                }
            }
        }
        let windowNumber = CGWindowID(window.windowNumber)
        if let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowNumber,
            [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
