import SwiftUI
import WorkshopCore

enum TaskTab: String, CaseIterable {
    case conversation = "Conversation"
    case board = "Board"
    case proposals = "Proposals"
    case files = "Files"
    case decisions = "Decisions"
    case usage = "Usage"
}

struct TaskPaneView: View {
    @EnvironmentObject var state: AppState
    var showBack: Bool = false
    @State private var tab: TaskTab = .conversation

    var body: some View {
        VStack(spacing: 0) {
            if showBack, state.selectedTaskID != nil {
                Button {
                    state.selectedTaskID = nil
                } label: {
                    Text("‹ Back to # projects")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            if let detail = state.detail {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.task.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WorkshopColors.primaryText)
                        Text("\(detail.task.phase.displayName) · \(detail.participants.count) participants · \(detail.task.state.displayName)")
                            .font(.system(size: 12))
                            .foregroundStyle(WorkshopColors.secondaryText)
                    }
                    Spacer()
                }
                .padding(12)
                Divider().overlay(WorkshopColors.divider)
                Picker("", selection: $tab) {
                    ForEach(TaskTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12).padding(.vertical, 6)
                Group {
                    switch tab {
                    case .conversation: ConversationView()
                    case .board: BoardView(subtasks: detail.subtasks)
                    case .proposals: EmptyTabView(text: "Arrives in Phase 3")
                    case .files: EmptyTabView(text: "Arrives in Phase 2")
                    case .decisions: EmptyTabView(text: "Arrives in Phase 3")
                    case .usage: UsageView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(WorkshopColors.divider)
                ReplyComposer()
            } else {
                Spacer()
                Text("Describe a task or send one from Codex.")
                    .font(.system(size: 14))
                    .foregroundStyle(WorkshopColors.secondaryText)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkshopColors.conversationSurface)
    }
}

struct ConversationView: View {
    @EnvironmentObject var state: AppState
    @State private var userScrolledUp = false
    @State private var newMessages = false

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                if newMessages {
                    Button("New messages") {
                        newMessages = false
                        scrollToEnd(proxy)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(WorkshopColors.selectedNavigation)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: state.messages.count) { _, _ in
                if userScrolledUp { newMessages = true } else { scrollToEnd(proxy) }
            }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = state.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        if message.kind == .systemEvent {
            Text(message.body)
                .font(.system(size: 12).italic())
                .foregroundStyle(WorkshopColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Avatar(author: message.author)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.author.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WorkshopColors.primaryText)
                        Text(message.createdAt, style: .time)
                            .font(.system(size: 11))
                            .foregroundStyle(WorkshopColors.secondaryText)
                        if message.deliveryState == .streaming {
                            Text("streaming")
                                .font(.system(size: 10).italic())
                                .foregroundStyle(WorkshopColors.secondaryText)
                        }
                    }
                    Text(message.body)
                        .font(.system(size: 14))
                        .foregroundStyle(WorkshopColors.primaryText)
                        .textSelection(.enabled)
                }
                Spacer()
            }
        }
    }
}

struct Avatar: View {
    let author: Principal

    var body: some View {
        let initial = author.displayName.prefix(1)
        let color: Color = {
            if case .engineer(let id) = author { return WorkshopColors.engineer(id) }
            return WorkshopColors.selectedNavigation
        }()
        Text(initial)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct BoardView: View {
    let subtasks: [Subtask]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(SubtaskState.allCases, id: \.self) { state in
                    let group = subtasks.filter { $0.state == state }
                    if !group.isEmpty {
                        Text(state.displayName.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(WorkshopColors.secondaryText)
                            .padding(.top, 8)
                        ForEach(group) { subtask in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(subtask.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(WorkshopColors.primaryText)
                                Text(subtask.ownerID.map {
                                    "\($0.displayName) owns · generation \(subtask.generation)"
                                } ?? "Unowned")
                                    .font(.system(size: 11))
                                    .foregroundStyle(WorkshopColors.secondaryText)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkshopColors.secondarySurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if subtasks.isEmpty {
                    Text("No subtasks.")
                        .font(.system(size: 13))
                        .foregroundStyle(WorkshopColors.secondaryText)
                }
            }
            .padding(16)
        }
    }
}

struct UsageView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            if let usage = state.detail?.usage {
                HStack(spacing: 24) {
                    UsageStat(label: "Input tokens",
                              value: usage.input.map(String.init) ?? "unknown")
                    UsageStat(label: "Output tokens",
                              value: usage.output.map(String.init) ?? "unknown")
                    UsageStat(label: "Cache read",
                              value: usage.cacheRead.map(String.init) ?? "unknown")
                    UsageStat(label: "Cache write",
                              value: usage.cacheWrite.map(String.init) ?? "unknown")
                }
                Text("Source: \(usage.source) · measured at turn end")
                    .font(.system(size: 11))
                    .foregroundStyle(WorkshopColors.secondaryText)
            } else {
                Text("No usage recorded yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(WorkshopColors.secondaryText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct UsageStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 11)).foregroundStyle(WorkshopColors.secondaryText)
        }
    }
}

struct EmptyTabView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(WorkshopColors.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReplyComposer: View {
    @EnvironmentObject var state: AppState
    @AppStorage("sendOnEnter") private var sendOnEnter = true
    @State private var draft = ""

    var body: some View {
        ComposerField(text: $draft, placeholder: "Reply to this task…",
                      focused: nil, sendOnEnter: sendOnEnter) {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            draft = ""
            Task { await state.postMessage(text) }
        }
        .padding(10)
        .background(WorkshopColors.secondarySurface)
    }
}

/// Multi-line composer: Return sends when sendOnEnter, Shift-Return inserts a newline.
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding? = nil
    let sendOnEnter: Bool
    let onSend: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(WorkshopColors.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            editor
        }
        .background(WorkshopColors.conversationSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkshopColors.divider))
    }

    @ViewBuilder
    private var editor: some View {
        let base = TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .font(.system(size: 13))
            .frame(minHeight: 38, maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            .onKeyPress(keys: [.return]) { press in
                guard sendOnEnter, !press.modifiers.contains(.shift) else { return .ignored }
                onSend()
                return .handled
            }
        if let focused {
            base.focused(focused)
        } else {
            base
        }
    }
}
