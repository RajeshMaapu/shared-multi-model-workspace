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
            }
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
        guard let window = NSApp.windows.first else { return }
        let windowNumber = CGWindowID(window.windowNumber)
        var image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowNumber,
                                            [.boundsIgnoreFraming, .bestResolution])
        if image == nil, let view = window.contentView {
            // Fallback: render the view without screen-capture permission.
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    return
                }
            }
        }
        if let cgImage = image {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        image = nil
    }
}
