import SwiftUI
import LitheAgentConversationModule

enum AgentContextUsagePresentation {
    static func percentage(_ usage: AgentContextUsage?, locale: Locale, precise: Bool = false) -> String {
        let fraction = usage?.fraction ?? 0
        return fraction.formatted(.percent.precision(.fractionLength(precise ? 1 : 0)).locale(locale))
    }

    static func details(_ usage: AgentContextUsage?, locale: Locale) -> String {
        guard let usage, usage.usedTokens > 0 else {
            return String(format: String(localized: "Context: %@"), percentage(usage, locale: locale, precise: true))
        }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(locale)
        let tokens = { (count: UInt64) in
            count >= 1_000 ? (Double(count) / 1_000).formatted(format) + "k" : count.formatted(.number.locale(locale))
        }
        return String(format: String(localized: "%@ · %@ / %@ context tokens"),
                      percentage(usage, locale: locale, precise: true), tokens(usage.usedTokens), tokens(usage.capacityTokens))
    }
}

/// Compact context ring with a zero placeholder until the Agent reports usage.
struct AgentContextUsageView: View {
    let usage: AgentContextUsage?
    @Environment(\.locale) private var locale

    private var color: Color {
        guard let usage else { return AgentPanelStyle.muted }
        if usage.fraction >= 1 { return LitheTheme.error }
        if usage.fraction >= 0.9 { return LitheTheme.warning }
        return AgentPanelStyle.secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(AgentPanelStyle.secondary.opacity(0.3), lineWidth: 1.5)
                if let usage {
                    Circle().trim(from: 0, to: min(usage.fraction, 1))
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }.frame(width: 12, height: 12)
            Text(AgentContextUsagePresentation.percentage(usage, locale: locale))
                .monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.vertical, 4)
        .fixedSize()
        .workbenchHoverHelp(Text(verbatim: AgentContextUsagePresentation.details(usage, locale: locale)), placement: .above)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context usage")
        .accessibilityValue(AgentContextUsagePresentation.details(usage, locale: locale))
        .accessibilityIdentifier("agent-context-usage")
    }
}
