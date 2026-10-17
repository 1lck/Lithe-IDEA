import SwiftUI
import LitheAgentConversationModule

enum AgentSubscriptionQuotaPresentation {
    static let fiveHours: UInt64 = 5 * 3_600
    static let sevenDays: UInt64 = 7 * 86_400

    enum UsageLevel: Equatable {
        case normal, warning, error, unknown

        var color: Color {
            switch self {
            case .normal: LitheTheme.success
            case .warning: LitheTheme.warning
            case .error: LitheTheme.error
            case .unknown: LitheTheme.HoverTooltip.infoForeground
            }
        }
    }

    static func level(_ usedPercent: Double?, stale: Bool = false) -> UsageLevel {
        guard !stale, let usedPercent else { return .unknown }
        if usedPercent > 90 { return .error }
        if usedPercent > 60 { return .warning }
        return .normal
    }

    static func duration(_ seconds: UInt64) -> String {
        if seconds.isMultiple(of: 86_400) { return "\(seconds / 86_400)d" }
        if seconds.isMultiple(of: 3_600) { return "\(seconds / 3_600)h" }
        return "\(seconds / 60)m"
    }

    /// Prefer the real short window, falling back to the weekly window. Other
    /// provider windows keep their actual duration rather than being relabelled.
    static func windows(_ quota: AgentSubscriptionQuota?) -> [AgentSubscriptionQuota.Window] {
        func priority(_ window: AgentSubscriptionQuota.Window) -> Int {
            window.limitSeconds == fiveHours ? 0 : (window.limitSeconds == sevenDays ? 1 : 2)
        }
        return (quota?.windows ?? []).sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            if ($0.name == "codex") != ($1.name == "codex") { return $0.name == "codex" }
            if $0.limitSeconds != $1.limitSeconds { return $0.limitSeconds < $1.limitSeconds }
            return $0.id < $1.id
        }
    }

    /// The window the compact ring shows: the most used one, so the ring turns
    /// yellow or red as soon as any window nears its limit.
    static func ringWindow(_ quota: AgentSubscriptionQuota?) -> AgentSubscriptionQuota.Window? {
        quota?.mostUsedWindow ?? windows(quota).first
    }

    static func percentage(_ window: AgentSubscriptionQuota.Window?, locale: Locale) -> String {
        window?.usedPercent.map {
            ($0 / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        } ?? "—"
    }

    static func usage(_ window: AgentSubscriptionQuota.Window, locale: Locale) -> String {
        String(format: AgentLocalization.string("%@ · %@ used", locale: locale),
               duration(window.limitSeconds), percentage(window, locale: locale))
    }

    static func notice(quota: AgentSubscriptionQuota?, failure: String?, stale: Bool) -> String.LocalizationValue? {
        if failure == "accountChanged" || failure == "unauthorized" {
            return "The local Codex account changed. Reconnect to refresh quota."
        }
        if stale { return "Quota is temporarily unavailable. The last value may be out of date." }
        return quota == nil ? "Waiting for subscription quota…" : nil
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
            let ring = AgentSubscriptionQuotaPresentation.ringWindow(quota)
            let level = AgentSubscriptionQuotaPresentation.level(ring?.usedPercent, stale: stale)
            // A single ring like Claude Desktop: gray track, filled by the most used
            // window and colored by its level. Window names and resets live in the card.
            ZStack {
                Circle().stroke(LitheTheme.settingsControlBorder, lineWidth: 2)
                if let used = ring?.usedPercent {
                    Circle().trim(from: 0, to: min(max(used / 100, 0), 1))
                        .stroke(level.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(1)
            .frame(width: LitheTheme.Metrics.toolbarIconSize, height: LitheTheme.Metrics.toolbarIconSize)
            .frame(width: LitheTheme.Metrics.toolbarIconButtonSize, height: LitheTheme.Metrics.toolbarIconButtonSize)
            .contentShape(Rectangle())
            .workbenchHoverCard(placement: .above, maximumWidth: AgentStatusCardMetrics.width) {
                panel(stale: stale).litheHoverTooltipSurface()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Codex subscription quota")
            .accessibilityValue(ring.map { AgentSubscriptionQuotaPresentation.usage($0, locale: locale) }
                                ?? AgentLocalization.string("Quota —", locale: locale))
            .accessibilityIdentifier("agent-subscription-quota")
        }
    }

    private func panel(stale: Bool) -> some View {
        AgentSubscriptionQuotaPanel(quota: quota, account: account, failure: failure, stale: stale)
            .padding(12)
            .frame(maxWidth: AgentStatusCardMetrics.width)
    }
}

/// Rich hover details for the compact text summary. Unknown/stale values
/// never become a healthy zero-percent bar.
struct AgentSubscriptionQuotaPanel: View {
    let quota: AgentSubscriptionQuota?
    let account: String?
    let failure: String?
    let stale: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex subscription quota").font(LitheTheme.uiFont(size: 12, weight: .semibold))
                if let account {
                    Text(verbatim: account).font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.HoverTooltip.infoForeground)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            ForEach(AgentSubscriptionQuotaPresentation.windows(quota)) { window in
                windowRow(window)
            }
            if let message = AgentSubscriptionQuotaPresentation.notice(quota: quota, failure: failure, stale: stale) {
                Text(verbatim: AgentLocalization.string(message, locale: locale))
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.HoverTooltip.infoForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(LitheTheme.HoverTooltip.foreground)
        .accessibilityIdentifier("agent-subscription-quota-panel")
    }

    private func windowRow(_ window: AgentSubscriptionQuota.Window) -> some View {
        let color = AgentSubscriptionQuotaPresentation.level(window.usedPercent, stale: stale).color
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                windowTitle(window)
                Spacer(minLength: 8)
                Text(String(format: AgentLocalization.string("Used %@", locale: locale),
                            AgentSubscriptionQuotaPresentation.percentage(window, locale: locale)))
                    .foregroundStyle(color).monospacedDigit()
            }
            .font(LitheTheme.uiFont(size: 11))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LitheTheme.HoverTooltip.infoForeground.opacity(0.25))
                    if let used = window.usedPercent {
                        Capsule().fill(color).frame(width: geometry.size.width * min(max(used / 100, 0), 1))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            if let reset = window.resetsAt {
                Text(String(format: AgentLocalization.string("Resets: %@", locale: locale),
                            Date(timeIntervalSince1970: Double(reset))
                                .formatted(.dateTime.month().day().hour().minute().locale(locale))))
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.HoverTooltip.infoForeground)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-subscription-quota-window-\(window.id)")
    }

    private func windowTitle(_ window: AgentSubscriptionQuota.Window) -> some View {
        HStack(spacing: 4) {
            if window.name != "codex" { Text(verbatim: window.name) }
            if window.limitSeconds == AgentSubscriptionQuotaPresentation.fiveHours { Text("5 hours") }
            else if window.limitSeconds == AgentSubscriptionQuotaPresentation.sevenDays { Text("7 days") }
            else { Text(verbatim: AgentSubscriptionQuotaPresentation.duration(window.limitSeconds)) }
        }
    }
}
