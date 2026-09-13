import SwiftUI
import WorkshopCore

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("selectedTaskID") private var persistedTaskID = ""
    @State private var windowWidth: CGFloat = 1440

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                RailView()
                SidebarView()
                if windowWidth >= 1100 || state.selectedTaskID == nil {
                    TaskListView()
                        .frame(width: 360)
                }
                Divider().overlay(WorkshopColors.divider)
                TaskPaneView(showBack: windowWidth < 1100)
            }
            .onAppear {
                windowWidth = geo.size.width
                if !persistedTaskID.isEmpty {
                    state.selectedTaskID = TaskID(persistedTaskID)
                }
            }
            .onChange(of: geo.size.width) { _, w in windowWidth = w }
            .onChange(of: state.selectedTaskID) { _, id in
                persistedTaskID = id?.rawValue ?? ""
            }
        }
        .background(WorkshopColors.conversationSurface)
        .overlay(alignment: .top) {
            if state.serviceUnavailable {
                Text("Service unavailable — local changes are read-only")
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(WorkshopColors.attention.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - App rail (64 px)

struct RailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("W")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 16)
            Label("Home", systemImage: "house.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(WorkshopColors.navigationBackground)
    }
}

// MARK: - Workspace sidebar (220 px)

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var searchFocused: Bool
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspace")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding([.top, .horizontal], 16)
            TextField("Search tasks, messages…", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.top, 8)
                .focused($searchFocused)
                .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
            Button("+ New task") { state.composerFocusRequest += 1 }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16).padding(.top, 12)
            SidebarItem(label: "Inbox", badge: nil)
            SectionLabel(label: "Channels")
            SidebarItem(label: "# projects", badge: nil)
            SidebarItem(label: "# research", badge: nil)
            SectionLabel(label: "Team")
            ForEach(state.engineers, id: \.engineer) { probe in
                EngineerRow(probe: probe)
            }
            Spacer()
            SidebarItem(label: "Settings", badge: nil)
                .padding(.bottom, 12)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(WorkshopColors.navigationBackground)
    }
}

struct SectionLabel: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
    }
}

struct SidebarItem: View {
    let label: String
    let badge: String?
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if let badge {
                Text(badge).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 3)
    }
}

struct EngineerRow: View {
    @EnvironmentObject var state: AppState
    let probe: AdapterProbe
    @State private var showCard = false

    var body: some View {
        Button { showCard.toggle() } label: { rowBody }
            .buttonStyle(.plain)
            .popover(isPresented: $showCard, arrowEdge: .trailing) {
                EngineerCard(probe: probe,
                             assignments: state.detail?.subtasks
                                 .filter { $0.ownerID == probe.engineer } ?? [])
            }
            .accessibilityLabel("\(probe.engineer.displayName), \(probe.health.label)")
    }

    private var rowBody: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(WorkshopColors.health(probe.health.kind))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(probe.engineer.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                Text(probe.health.detail.isEmpty
                     ? probe.health.label
                     : "\(probe.health.label) · \(probe.health.detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
}
