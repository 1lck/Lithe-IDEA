import SwiftUI
import LitheAgentConversationModule

enum AgentContextUsagePresentation {
    static func percentage(_ usage: AgentContextUsage?, locale: Locale, precise: Bool = false) -> String {
        let fraction = usage?.fraction ?? 0
        return fraction.formatted(.percent.precision(.fractionLength(precise ? 1 : 0)).locale(locale))
    }

    static func details(_ usage: AgentContextUsage?, locale: Locale) -> String {
        guard let usage, usage.usedTokens > 0 else {
            return String(format: AgentLocalization.string("Context: %@", locale: locale), percentage(usage, locale: locale, precise: true))
        }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(locale)
        let tokens = { (count: UInt64) in
            count >= 1_000 ? (Double(count) / 1_000).formatted(format) + "k" : count.formatted(.number.locale(locale))
        }
        return String(format: AgentLocalization.string("%@ · %@ / %@ context tokens", locale: locale),
                      percentage(usage, locale: locale, precise: true), tokens(usage.usedTokens), tokens(usage.capacityTokens))
    }
}

/// Compact context ring with a zero placeholder until the Agent reports usage.
struct AgentContextUsageView: View {
    let usage: AgentContextUsage?
    /// Estimated prompt composition from the optional model call proxy.
    var composition: AgentModelCall.Context?
    var showsPercentage = true
    @Environment(\.locale) private var locale
    private var ringStroke: CGFloat { showsPercentage ? 1.5 : 2 }
    private var ringInset: CGFloat { showsPercentage ? 0 : ringStroke / 2 }

    private var color: Color {
        guard let usage else { return LitheTheme.HoverTooltip.infoForeground }
        if usage.fraction >= 1 { return LitheTheme.error }
        if usage.fraction >= 0.9 { return LitheTheme.warning }
        return LitheTheme.HoverTooltip.infoForeground
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().inset(by: ringInset)
                    .stroke(showsPercentage ? LitheTheme.settingsControlBorder : LitheTheme.HoverTooltip.infoForeground,
                            lineWidth: ringStroke)
                if let usage {
                    Circle().inset(by: ringInset).trim(from: 0, to: min(usage.fraction, 1))
                        .stroke(showsPercentage || usage.fraction >= 0.9 ? color : LitheTheme.toolWindowText,
                                style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }.frame(width: showsPercentage ? 12 : LitheTheme.Metrics.toolbarIconSize,
                    height: showsPercentage ? 12 : LitheTheme.Metrics.toolbarIconSize)
            if showsPercentage {
                Text(AgentContextUsagePresentation.percentage(usage, locale: locale))
                    .monospacedDigit().lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .font(LitheTheme.smallFont)
        .padding(.horizontal, showsPercentage ? 4 : 0)
        .frame(width: showsPercentage ? nil : LitheTheme.Metrics.toolbarIconButtonSize,
               height: LitheTheme.Metrics.toolbarIconButtonSize)
        .fixedSize()
        .workbenchHoverCard(placement: .above, maximumWidth: AgentStatusCardMetrics.width) {
            AgentContextUsageCard(usage: usage, composition: composition)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context usage")
        .accessibilityValue(AgentContextUsagePresentation.details(usage, locale: locale))
        .accessibilityIdentifier("agent-context-usage")
    }
}
