import AppKit
import ServiceManagement
import SwiftUI

/// Settings pane (§4.5): background helper registration via SMAppService,
/// notification mute, message-send shortcut. Helper registration only ever
/// touches ai.maapu.workshop.daemon.plist — no other LaunchAgents.
struct WorkshopSettingsView: View {
    @AppStorage("sendOnEnter") private var sendOnEnter = true
    @AppStorage("muteNotifications") private var muteNotifications = false
    @AppStorage("runHelperInBackground") private var runHelper = false
    @State private var helperStatus: SMAppService.Status = .notRegistered
    @State private var helperError: String?

    private var agent: SMAppService {
        SMAppService.agent(plistName: "ai.maapu.workshop.daemon.plist")
    }

    var body: some View {
        Form {
            Toggle("Send messages with Return (Shift-Return for newline)",
                   isOn: $sendOnEnter)

            Section("Background helper") {
                Toggle("Run Workshop helper in the background",
                       isOn: $runHelper)
                    .onChange(of: runHelper) { _, on in applyHelper(on) }
                LabeledContent("Helper status") {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                if let helperError {
                    Text(helperError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Text("Stop background work pauses all tasks and exits the "
                     + "daemon; the helper stays registered but idle.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Mute notifications", isOn: $muteNotifications)
                Text("Muting never pauses work — it only silences banners.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { helperStatus = agent.status }
    }

    private var statusText: String {
        switch helperStatus {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires approval in Login Items"
        case .notFound: return "Helper not found in this build"
        @unknown default: return "Unknown"
        }
    }

    private func applyHelper(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
        helperStatus = agent.status
    }
}
