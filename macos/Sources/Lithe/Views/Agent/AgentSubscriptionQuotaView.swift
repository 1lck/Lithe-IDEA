import SwiftUI
import LitheAgentConversationModule

enum AgentSubscriptionQuotaPresentation {
    static func duration(_ seconds: UInt64) -> String {
        if seconds.isMultiple(of: 86_400) { return "\(seconds / 86_400)d" }
        if seconds.isMultiple(of: 3_600) { return "\(seconds / 3_600)h" }
        return "\(seconds / 60)m"
    }

    static func usage(_ window: AgentSubscriptionQuota.Window, locale: Locale) -> String {
        let percent = window.usedPercent.map {
            ($0 / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        } ?? "—"
        return String(format: String(localized: "%@ · %@ used"), duration(window.limitSeconds), percent)
    }
}

/// Only subscription connections mount this view; it owns no network or credentials.
struct AgentSubscriptionQuotaView: View {
    let quota: AgentSubscriptionQuota?
    let account: String?
    let failure: String?
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let stale = failure != nil || quota?.isStale(at: timeline.date) == true
            HStack(spacing: 4) {
                Image(systemName: stale ? "clock" : "gauge.medium")
                Text(quota?.mostUsedWindow.map { AgentSubscriptionQuotaPresentation.usage($0, locale: locale) }
                     ?? String(localized: "Quota —"))
                    .monospacedDigit().lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(stale ? AgentPanelStyle.muted : color)
            .fixedSize()
            .padding(.vertical, 4)
            .workbenchHoverHelp(Text(verbatim: details(stale: stale)), placement: .above)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex subscription quota")
            .accessibilityValue(details(stale: stale))
            .accessibilityIdentifier("agent-subscription-quota")
        }
    }

    private var color: Color {
        let used = quota?.mostUsedWindow?.usedPercent ?? 0
        return used >= 100 ? LitheTheme.error : (used >= 90 ? LitheTheme.warning : AgentPanelStyle.secondary)
    }

    private func details(stale: Bool) -> String {
        var lines = [String(localized: "Codex subscription quota")]
        if let account { lines.append(account) }
        for window in quota?.windows ?? [] {
            let prefix = window.name == "codex" ? "" : "\(window.name) · "
            lines.append(prefix + AgentSubscriptionQuotaPresentation.usage(window, locale: locale))
            if let reset = window.resetsAt {
                let date = Date(timeIntervalSince1970: Double(reset))
                    .formatted(.dateTime.month().day().hour().minute().locale(locale))
                lines.append(String(format: String(localized: "Resets: %@"), date))
            }
        }
        if let quota {
            let date = Date(timeIntervalSince1970: Double(quota.fetchedAt))
                .formatted(.dateTime.hour().minute().locale(locale))
            lines.append(String(format: String(localized: "Updated: %@"), date))
        }
        if failure == "accountChanged" || failure == "unauthorized" {
            lines.append(String(localized: "The local Codex account changed. Reconnect to refresh quota."))
        } else if stale {
            lines.append(String(localized: "Quota is temporarily unavailable. The last value may be out of date."))
        } else if quota == nil {
            lines.append(String(localized: "Waiting for subscription quota…"))
        }
        return lines.joined(separator: "\n")
    }
}
