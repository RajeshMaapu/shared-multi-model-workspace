import SwiftUI
import AppKit
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
    @State private var tab: TaskTab = {
        // Dev hook for screenshots: WORKSHOP_TAB=usage|files|board|conversation
        if let raw = ProcessInfo.processInfo.environment["WORKSHOP_TAB"],
           let t = TaskTab(rawValue: raw.lowercased().capitalized) {
            return t
        }
        return .conversation
    }()

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
                        if let alert = state.selectedTaskCapacityAlert() {
                            Chip(text: "⚠ " + alert,
                                 color: WorkshopColors.attention)
                                .padding(.top, 4)
                        }
                    }
                    Spacer()
                    taskActionsMenu(detail.task)
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
                    case .proposals: ProposalsView()
                    case .files: FilesView()
                    case .decisions: DecisionsView()
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
        // Dedupe by (engineer, state): a running engineer with several pending
        // wakeup rows must not repeat the same chip.
        var seen = Set<String>()
        let queued = detail.pendingWakeups.filter { w in
            !running.contains(w.engineer) && seen.insert(w.engineer.rawValue + w.state).inserted
        }
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

    /// Task-level actions (§8.2): pause/resume/cancel/accept/convert.
    /// All are user-authority operations routed through the daemon.
    @ViewBuilder
    private func taskActionsMenu(_ task: WorkshopTask) -> some View {
        Menu {
            Button("Pause") { Task { await state.pauseTask() } }
                .disabled(task.state != .working)
            Button("Resume") { Task { await state.resumeTask() } }
                .disabled(task.state != .paused)
            Button("Cancel task") { Task { await state.cancelTask() } }
                .disabled(![.ready, .working].contains(task.state))
            Divider()
            Button("Accept task") { Task { await state.acceptTask() } }
                .disabled(task.state != .verifying)
            Button("Convert to research") {
                Task { await state.convertToResearch() }
            }
            .disabled(task.state != .paused)
            Divider()
            Button("Export…") { exportTask() }
        } label: {
            Text("Actions")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// workshop.exportTask — pick a destination folder, then export (§14.1).
    private func exportTask() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.exportSelectedTask(destDir: url.path) }
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
            // Recovery banner after restart/sleep-wake reconcile (§14.1).
            if let banner = state.recoveryBanner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WorkshopColors.primaryText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorkshopColors.attention.opacity(0.15))
            }
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if state.hasEarlierMessages {
                            Button("Load earlier") {
                                // Anchor on the first visible message so the
                                // scroll position survives the prepend (T31).
                                let anchor = state.messages.first?.id
                                Task {
                                    await state.loadEarlierMessages()
                                    if let anchor { proxy.scrollTo(anchor) }
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(WorkshopColors.secondaryText)
                            .frame(maxWidth: .infinity)
                        }
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

    private static let fieldOrder = ["type", "summary", "reviewer", "message",
                                     "artifact_ids", "validation", "description",
                                     "proposal_id", "revision", "severity",
                                     "disposition", "subtask", "proposed_owner",
                                     "owner", "rationale", "kind", "scope",
                                     "recommendation", "result_message_id",
                                     "evidence"]

    /// Ordered known fields first, then any remaining keys alphabetically, so
    /// assignment/decision/review cards never silently drop fields.
    private var orderedKeys: [String] {
        var keys: [String] = []
        for key in Self.fieldOrder where payload[key] != nil { keys.append(key) }
        if case .object(let object) = payload {
            for key in object.keys.sorted() where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkshopColors.secondaryText)
            ForEach(orderedKeys, id: \.self) { key in
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

/// Kanban board: one column per subtask state, cards show owner, generation,
/// risk, verification outcome, and dependencies (§5.5 proportional review data).
struct BoardView: View {
    let subtasks: [Subtask]

    private static let columns: [SubtaskState] =
        [.ready, .claimed, .working, .review, .blocked, .done]

    private func title(for id: String) -> String {
        subtasks.first { $0.id.rawValue == id }?.title ?? id
    }

    var body: some View {
        if subtasks.isEmpty {
            EmptyTabView(text: "No subtasks.")
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Self.columns, id: \.self) { column in
                        let group = subtasks.filter { $0.state == column }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(column.displayName.uppercased()) · \(group.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WorkshopColors.secondaryText)
                            ForEach(group) { subtask in
                                card(subtask)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: 220, alignment: .top)
                    }
                }
                .padding(16)
            }
        }
    }

    private func card(_ subtask: Subtask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(subtask.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WorkshopColors.primaryText)
            Text(subtask.ownerID.map {
                "\($0.displayName) · gen \(subtask.generation)"
            } ?? "Unowned · gen \(subtask.generation)")
                .font(.system(size: 11))
                .foregroundStyle(WorkshopColors.secondaryText)
            HStack(spacing: 6) {
                Chip(text: "risk: \(subtask.risk)",
                     color: subtask.risk == "high"
                        ? .orange : WorkshopColors.selectedNavigation.opacity(0.6))
                Chip(text: "verify: \(subtask.verification)",
                     color: subtask.verification == "passed"
                        ? .green
                        : (subtask.verification == "changes_requested"
                           ? .orange : WorkshopColors.selectedNavigation.opacity(0.6)))
            }
            if !subtask.dependencies.isEmpty {
                Text("depends on: "
                     + subtask.dependencies.map(title(for:)).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(WorkshopColors.secondaryText)
            }
            if let lease = subtask.leaseExpiresAt {
                Text("Lease expires \(lease, style: .time)")
                    .font(.system(size: 10))
                    .foregroundStyle(WorkshopColors.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkshopColors.secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkshopColors.divider))
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

// MARK: - Phase 3: Proposals / Report / Decisions

/// Decoded fields shared by proposal and report JSON payloads.
private func contentJSON(_ raw: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
}

private func strings(_ value: JSONValue?) -> [String] {
    value?.arrayValue?.compactMap(\.stringValue) ?? []
}

/// Proposals tab: private draft progress while researching, published proposal
/// cards with their reviews after publication, and the consolidated report
/// with user-only approval controls (§5.3, T12, §12.5 keyboard access).
struct ProposalsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = state.lastActionError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                if let detail = state.detail,
                   detail.task.state == .researching {
                    Text("\(detail.draftProposalCount) of "
                         + "\(detail.participants.count) proposals drafted "
                         + "(private until published)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WorkshopColors.secondaryText)
                }
                let published = state.proposals.filter { $0.visibility == "published" }
                if !published.isEmpty {
                    Text("PROPOSALS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WorkshopColors.secondaryText)
                    // Cards side by side; scroll horizontally if they exceed width.
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(published) { proposal in
                                ProposalCard(proposal: proposal,
                                             reviews: reviews(for: proposal))
                                    .frame(width: 320, alignment: .top)
                            }
                        }
                    }
                }
                ForEach(state.reports) { report in
                    ReportCard(report: report)
                }
                if published.isEmpty && state.reports.isEmpty,
                   state.detail?.task.state != .researching {
                    EmptyTabView(text: "No proposals or reports yet.")
                }
            }
            .padding(16)
        }
    }

    /// Review messages whose structured payload targets this proposal.
    private func reviews(for proposal: Proposal) -> [Message] {
        state.messages.filter { message in
            guard message.kind == .review, let s = message.structured,
                  let payload = contentJSON(s),
                  payload["type"]?.stringValue == "review" else { return false }
            return payload["proposal_id"]?.stringValue == proposal.id
        }
    }
}

/// One published proposal: title, summary, approach, alternatives, risks,
/// proposed ownership — with peer reviews beneath.
struct ProposalCard: View {
    let proposal: Proposal
    let reviews: [Message]

    var body: some View {
        let content = contentJSON(proposal.content)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(proposal.author.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WorkshopColors.engineer(proposal.author))
                Spacer()
                Text(proposal.createdAt, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(WorkshopColors.secondaryText)
            }
            Text(content?["title"]?.stringValue ?? "(untitled)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WorkshopColors.primaryText)
            field("Summary", content?["summary"]?.stringValue)
            field("Approach", content?["approach"]?.stringValue)
            if let alternatives = content?["alternatives"]?.arrayValue,
               !alternatives.isEmpty {
                Text("Alternatives")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkshopColors.secondaryText)
                ForEach(alternatives.indices, id: \.self) { i in
                    let alt = alternatives[i]
                    Text("• \(alt["title"]?.stringValue ?? "") — "
                         + (alt["summary"]?.stringValue ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(WorkshopColors.primaryText)
                }
            }
            field("Risks", strings(content?["risks"]).joined(separator: "; "))
            if let ownership = content?["proposed_ownership"]?.arrayValue,
               !ownership.isEmpty {
                Text("Proposed ownership")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkshopColors.secondaryText)
                ForEach(ownership.indices, id: \.self) { i in
                    let item = ownership[i]
                    Text("• \(item["subtask_title"]?.stringValue ?? "") → "
                         + (item["proposed_owner"]?.stringValue ?? "?"))
                        .font(.system(size: 12))
                        .foregroundStyle(WorkshopColors.primaryText)
                }
            }
            if !reviews.isEmpty {
                Divider().overlay(WorkshopColors.divider)
                Text("REVIEWS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WorkshopColors.secondaryText)
                ForEach(reviews) { review in
                    ReviewRow(message: review)
                }
            }
        }
        .padding(12)
        .background(WorkshopColors.secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkshopColors.divider))
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkshopColors.secondaryText)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(WorkshopColors.primaryText)
                .textSelection(.enabled)
        }
    }
}

/// One review under a proposal/result: severity + disposition chips and body.
struct ReviewRow: View {
    let message: Message

    var body: some View {
        let payload = message.structured.flatMap(contentJSON)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.author.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkshopColors.primaryText)
                if let severity = payload?["severity"]?.stringValue {
                    Chip(text: severity, color: severity == "high" ? .red
                         : (severity == "medium" ? .orange : .gray))
                }
                if let disposition = payload?["disposition"]?.stringValue {
                    Chip(text: disposition.replacingOccurrences(of: "_", with: " "),
                         color: disposition == "agree" ? .green
                         : (disposition == "disagree" ? .red : .orange))
                }
            }
            Text(message.body)
                .font(.system(size: 12))
                .foregroundStyle(WorkshopColors.primaryText)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

/// Consolidated report card with user-only approval controls. Buttons are
/// standard focusable controls so approval is reachable by keyboard (§12.5).
struct ReportCard: View {
    @EnvironmentObject var state: AppState
    let report: Report
    @State private var changesComment = ""
    @State private var alternativeIndex = 0

    private var task: WorkshopTask? { state.detail?.task }

    var body: some View {
        let content = contentJSON(report.content)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Report r\(report.revision) · \(report.author)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WorkshopColors.secondaryText)
                Spacer()
                if task?.approvalRevision == report.revision {
                    Chip(text: "Approved r\(report.revision)", color: .green)
                } else if let approved = task?.approvalRevision,
                          approved < report.revision {
                    Chip(text: "Approval r\(approved) no longer covers "
                         + "r\(report.revision)", color: .orange)
                }
            }
            if let recommendation = content?["recommendation"]?.stringValue {
                Text(recommendation)
                    .font(.system(size: 13))
                    .foregroundStyle(WorkshopColors.primaryText)
                    .textSelection(.enabled)
            }
            if let alternatives = content?["alternatives"]?.arrayValue,
               !alternatives.isEmpty {
                ForEach(alternatives.indices, id: \.self) { i in
                    Text("Alt \(i): \(alternatives[i]["title"]?.stringValue ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(WorkshopColors.secondaryText)
                }
            }
            if let disagreements = content?["disagreements"]?.arrayValue,
               !disagreements.isEmpty {
                Text("Disagreements")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkshopColors.secondaryText)
                ForEach(disagreements.indices, id: \.self) { i in
                    let d = disagreements[i]
                    let positions = (d["positions"]?.arrayValue ?? [])
                        .map { "\($0["engineer"]?.stringValue ?? "?"): "
                             + "\($0["position"]?.stringValue ?? "")" }
                        .joined(separator: " · ")
                    Text("• \(d["topic"]?.stringValue ?? "") — \(positions)")
                        .font(.system(size: 12))
                        .foregroundStyle(WorkshopColors.primaryText)
                }
            }
            if task?.state == .awaitingArchitectureApproval {
                HStack(spacing: 10) {
                    Button("Approve architecture") {
                        Task {
                            await state.approveArchitecture(
                                reportRevision: report.revision)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    Picker("Alternative", selection: $alternativeIndex) {
                        let count = content?["alternatives"]?.arrayValue?.count ?? 0
                        ForEach(0..<max(count, 1), id: \.self) {
                            Text("Alt \($0)").tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Button("Choose alternative") {
                        Task {
                            await state.chooseAlternative(
                                reportRevision: report.revision,
                                index: alternativeIndex)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Request changes…", text: $changesComment)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 280)
                    Button("Request changes") {
                        let comment = changesComment
                        changesComment = ""
                        Task {
                            await state.requestChanges(
                                reportRevision: report.revision,
                                comment: comment)
                        }
                    }
                    .disabled(changesComment.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(WorkshopColors.secondarySurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkshopColors.divider))
    }
}

/// Decisions tab: chronological record of approvals, allocations, disputes,
/// escalations, acceptances, cancellations.
struct DecisionsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.decisions.isEmpty {
            EmptyTabView(text: "No decisions recorded yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.decisions) { decision in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Chip(text: decision.kind.replacingOccurrences(
                                    of: "_", with: " "),
                                     color: WorkshopColors.selectedNavigation)
                                if let revision = decision.revision {
                                    Text("r\(revision)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(WorkshopColors.secondaryText)
                                }
                                if let scope = decision.scope {
                                    Text(scope)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(WorkshopColors.secondaryText)
                                }
                                Text(decision.author)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(WorkshopColors.primaryText)
                                Spacer()
                                Text(decision.createdAt, style: .time)
                                    .font(.system(size: 10))
                                    .foregroundStyle(WorkshopColors.secondaryText)
                            }
                            Text(decision.body)
                                .font(.system(size: 12))
                                .foregroundStyle(WorkshopColors.primaryText)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkshopColors.secondarySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            }
        }
    }
}
