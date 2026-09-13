import SwiftUI
import WorkshopCore

/// Engineer card popover (§3.7): adapter kind, version, qualification badge,
/// model selector, reasoning setting, health, quota, current assignments.
struct EngineerCard: View {
    let probe: AdapterProbe
    let assignments: [Subtask]

    private var adapterKind: String {
        switch probe.engineer {
        case .devin, .kimi: return "ACP harness"
        case .deepseek: return "Direct API"
        }
    }

    private var reasoning: String {
        switch probe.engineer {
        case .devin: return "fusion pairing"
        case .kimi: return "high"
        case .deepseek: return "max"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(WorkshopColors.health(probe.health.kind))
                    .frame(width: 10, height: 10)
                Text(probe.engineer.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WorkshopColors.primaryText)
                Spacer()
                Text(probe.tested ? "qualified" : "UNTESTED")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(probe.tested
                                ? WorkshopColors.success.opacity(0.2)
                                : WorkshopColors.attention.opacity(0.25))
                    .foregroundStyle(probe.tested
                                     ? WorkshopColors.success
                                     : WorkshopColors.attention)
                    .clipShape(Capsule())
            }
            row("Adapter", adapterKind)
            row("Version", probe.versions["binary"] ?? "unknown")
            row("Model", probe.effectiveModel ?? "default")
            row("Reasoning", reasoning)
            row("Health", probe.health.detail.isEmpty
                ? probe.health.label : probe.health.detail)
            row("Quota", "unknown")
            if !assignments.isEmpty {
                Text("Assignments")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkshopColors.secondaryText)
                ForEach(assignments) { sub in
                    Text("\(sub.title) · gen \(sub.generation) · \(sub.state.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(WorkshopColors.primaryText)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(WorkshopColors.conversationSurface)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkshopColors.secondaryText)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(WorkshopColors.primaryText)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
