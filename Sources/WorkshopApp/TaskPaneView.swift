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
                        statusChips(detail)
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
                    case .files: FilesView()
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

    /// Status chips derived from running turns + pending wakeups (§3.x).
    @ViewBuilder
    private func statusChips(_ detail: TaskDetail) -> some View {
        let running = Set(detail.runningEngineers)
        let queued = detail.pendingWakeups.filter { !running.contains($0.engineer) }
        if !running.isEmpty || !queued.isEmpty {
            HStack(spacing: 6) {
                ForEach(detail.runningEngineers, id: \.self) { e in
                    Chip(text: "\(e.displayName) · running",
                         color: WorkshopColors.engineer(e))
                }
                ForEach(queued, id: \.engineer) { w in
                    Chip(text: w.state == "running"
                         ? "\(w.engineer.displayName) · waiting for tool"
                         : "\(w.engineer.displayName) · waiting for peer",
                         color: WorkshopColors.engineer(w.engineer).opacity(0.7))
                }
            }
            .padding(.top, 4)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(WorkshopColors.primaryText)
            .clipShape(Capsule())
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
                    Text(highlightedMentions(message.body))
                        .font(.system(size: 14))
                        .foregroundStyle(WorkshopColors.primaryText)
                        .textSelection(.enabled)
                    if let structured = message.structured,
                       let card = try? JSONDecoder().decode(JSONValue.self,
                                                            from: Data(structured.utf8)) {
                        StructuredCard(kind: message.kind, payload: card)
                    }
                }
                Spacer()
            }
        }
    }

    /// Highlight @engineer mentions in the engineer's accent color.
    private func highlightedMentions(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for engineer in EngineerID.allCases {
            let needle = "@\(engineer.rawValue)"
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: needle) {
                attributed[range].foregroundColor = WorkshopColors.engineer(engineer)
                attributed[range].font = .system(size: 14, weight: .semibold)
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// Compact card for structured message payloads (review requests, results).
struct StructuredCard: View {
    let kind: MessageKind
    let payload: JSONValue

    private static let fieldOrder = ["summary", "reviewer", "message",
                                     "artifact_ids", "validation", "description"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkshopColors.secondaryText)
            ForEach(Self.fieldOrder, id: \.self) { key in
                if let value = payload[key] {
                    fieldRow(key, value)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(WorkshopColors.secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkshopColors.divider))
    }

    @ViewBuilder
    private func fieldRow(_ key: String, _ value: JSONValue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkshopColors.secondaryText)
                .frame(width: 84, alignment: .leading)
            Text(render(value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(WorkshopColors.primaryText)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func render(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        default:
            if let data = try? JSONEncoder().encode(v) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
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
                                if let lease = subtask.leaseExpiresAt {
                                    Text("Lease expires \(lease, style: .time) (\(lease.relativeDescription))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(WorkshopColors.secondaryText)
                                }
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

/// Artifacts tab: hash-named files with provenance + a bounded preview.
struct FilesView: View {
    @EnvironmentObject var state: AppState
    @State private var selected: Artifact?

    var body: some View {
        if state.artifacts.isEmpty {
            EmptyTabView(text: "No artifacts published yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.artifacts) { artifact in
                        Button { selected = artifact } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name(of: artifact))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(WorkshopColors.primaryText)
                                Text("sha256 \(artifact.contentHash.prefix(12))… · "
                                     + "\(artifact.producer) · \(artifact.validation) · "
                                     + artifact.createdAt.relativeDescription)
                                    .font(.system(size: 11))
                                    .foregroundStyle(WorkshopColors.secondaryText)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkshopColors.secondarySurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .sheet(item: $selected) { artifact in
                ArtifactPreview(artifact: artifact,
                                path: state.workshopHome + "/" + artifact.relativePath)
            }
        }
    }

    private func name(of a: Artifact) -> String {
        (a.relativePath as NSString).lastPathComponent
    }
}

/// Preview of one artifact: text or PNG, bounded to 1 MiB.
struct ArtifactPreview: View {
    let artifact: Artifact
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text((artifact.relativePath as NSString).lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            preview
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var preview: some View {
        if let data = loadData() {
            if path.lowercased().hasSuffix(".png"),
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let text = String(data: data, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text("Binary content — \(data.count) bytes")
                    .foregroundStyle(WorkshopColors.secondaryText)
            }
        } else {
            Text("Cannot read file (missing or over 1 MiB).")
                .foregroundStyle(WorkshopColors.secondaryText)
        }
    }

    private func loadData() -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size <= 1024 * 1024 else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}

/// Per-engineer usage table plus totals (nil counters shown as "unknown").
struct UsageView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if state.usageRows.isEmpty {
                    Text("No usage recorded yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(WorkshopColors.secondaryText)
                } else {
                    ForEach(EngineerID.allCases, id: \.self) { engineer in
                        let rows = state.usageRows.filter { $0.engineerID == engineer }
                        if !rows.isEmpty {
                            Text(engineer.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(WorkshopColors.secondaryText)
                            ForEach(rows.indices, id: \.self) { i in
                                usageRow(rows[i])
                            }
                        }
                    }
                    totals
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func usageRow(_ row: UsageSampleRecord) -> some View {
        HStack(spacing: 16) {
            Text(row.observedAt, style: .time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(WorkshopColors.secondaryText)
                .frame(width: 70, alignment: .leading)
            Group {
                Text(cell(row.sample.input))
                Text(cell(row.sample.output))
                Text(cell(row.sample.cacheRead))
                Text(cell(row.sample.cacheWrite))
            }
            .font(.system(size: 11, design: .monospaced))
            Text(row.sample.source)
                .font(.system(size: 10))
                .foregroundStyle(WorkshopColors.secondaryText)
            Spacer()
        }
    }

    private func cell(_ v: Int?) -> String { v.map(String.init) ?? "unknown" }

    private var totals: some View {
        let rows = state.usageRows
        func sum(_ key: (UsageSample) -> Int?) -> String {
            let values = rows.compactMap { key($0.sample) }
            return values.isEmpty ? "unknown" : String(values.reduce(0, +))
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Totals")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WorkshopColors.secondaryText)
            Text("in \(sum(\.input)) · out \(sum(\.output)) · "
                 + "cache r \(sum(\.cacheRead)) · cache w \(sum(\.cacheWrite))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(WorkshopColors.primaryText)
        }
        .padding(.top, 8)
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
