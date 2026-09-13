import SwiftUI
import WorkshopCore

struct TaskListView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var composerFocused: Bool
    @AppStorage("sendOnEnter") private var sendOnEnter = true
    @State private var draft = ""
    @State private var phase: TaskPhase = .execution

    var body: some View {
        VStack(spacing: 0) {
            Text("# projects")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WorkshopColors.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            Divider().overlay(WorkshopColors.divider)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.tasks, id: \.id) { task in
                        TaskRow(task: task,
                                selected: task.id == state.selectedTaskID)
                        .onTapGesture { state.selectedTaskID = task.id }
                        Divider().overlay(WorkshopColors.divider)
                    }
                    if state.tasks.isEmpty {
                        Text("Describe a task or send one from Codex.")
                            .font(.system(size: 13))
                            .foregroundStyle(WorkshopColors.secondaryText)
                            .padding(24)
                    }
                }
            }
            Divider().overlay(WorkshopColors.divider)
            VStack(spacing: 6) {
                Picker("", selection: $phase) {
                    Text("Execute").tag(TaskPhase.execution)
                    Text("Research proposal").tag(TaskPhase.researchProposal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ComposerField(text: $draft,
                              placeholder: "Describe an idea, research question, or task for the team…",
                              focused: $composerFocused,
                              sendOnEnter: sendOnEnter) {
                    submit()
                }
            }
            .padding(10)
            .background(WorkshopColors.secondarySurface)
        }
        .background(WorkshopColors.conversationSurface)
        .onChange(of: state.composerFocusRequest) { _, _ in composerFocused = true }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let title = String(text.prefix(80))
        Task { await state.createTask(title: title, objective: text, phase: phase) }
    }
}

struct TaskRow: View {
    let task: WorkshopTask
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(WorkshopColors.engineer(.devin))
                .frame(width: 20, height: 20)
                .overlay(Text("Y").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("You")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WorkshopColors.secondaryText)
                    Spacer()
                    Text(task.updatedAt.relativeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(WorkshopColors.secondaryText)
                }
                Text(task.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(WorkshopColors.primaryText)
                    .lineLimit(1)
                Text(task.brief)
                    .font(.system(size: 12))
                    .foregroundStyle(WorkshopColors.secondaryText)
                    .lineLimit(2)
                Text("\(task.phase.displayName) · \(task.state.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(WorkshopColors.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WorkshopColors.selectedNavigation.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }
}
