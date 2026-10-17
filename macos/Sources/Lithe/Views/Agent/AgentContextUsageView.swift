import SwiftUI
import LitheAgentConversationModule

enum AgentContextUsagePresentation {
    static func percentage(_ usage: AgentContextUsage?, locale: Locale, precise: Bool = false) -> String {
        guard let usage else { return "—" }
        return usage.fraction.formatted(.percent.precision(.fractionLength(precise ? 1 : 0)).locale(locale))
    }

    static func details(_ usage: AgentContextUsage?, locale: Locale) -> String {
        guard let usage else {
            return AgentLocalization.string("The Agent has not reported context usage yet.", locale: locale)
        }
        return String(format: AgentLocalization.string("%@ · %@ / %@ context used", locale: locale),
                      percentage(usage, locale: locale, precise: true), tokens(usage.usedTokens, locale: locale),
                      tokens(usage.capacityTokens, locale: locale))
    }

    static func tokens(_ count: UInt64, locale: Locale) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(locale)
        return count >= 1_000 ? (Double(count) / 1_000).formatted(format) + "K" : count.formatted(.number.locale(locale))
    }
}

/// Compact context ring. It stays hidden until the Agent's first usage report so
/// an empty indicator cannot be mistaken for zero occupancy; the inline detail
/// panels keep rendering their own unknown state after a report disappears.
struct AgentContextUsageView: View {
    let usage: AgentContextUsage?
    /// Estimated prompt composition from the optional model call proxy.
    var composition: AgentModelCall.Context?
    var showsPercentage = true
    /// Inline detail consumers can suppress the compact hover tooltip.
    var showsHoverCard = true
    /// Toolbar consumers hide the whole ring while no report exists; the status
    /// row and inline cards render the unknown state explicitly.
    var isHiddenUntilReported = false
    @Environment(\.locale) private var locale
    private var ringStroke: CGFloat { showsPercentage ? 1.5 : 2 }
    private var ringInset: CGFloat { showsPercentage ? 0 : ringStroke / 2 }

    private var color: Color {
        guard let usage else { return LitheTheme.HoverTooltip.infoForeground }
        if usage.fraction >= 1 { return LitheTheme.error }
        if usage.fraction >= 0.9 { return LitheTheme.warning }
        return LitheTheme.HoverTooltip.infoForeground
    }

    @ViewBuilder
    var body: some View {
        if !(isHiddenUntilReported && usage == nil) {
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
                   height: showsPercentage ? nil : LitheTheme.Metrics.toolbarIconButtonSize)
            .fixedSize()
            .contentShape(Rectangle())
            .modifier(AgentContextHoverCard(isEnabled: showsHoverCard, usage: usage))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context usage")
            .accessibilityValue(AgentContextUsagePresentation.details(usage, locale: locale))
            .accessibilityIdentifier("agent-context-usage")
        }
    }
}

private struct AgentContextHoverCard: ViewModifier {
    let isEnabled: Bool
    let usage: AgentContextUsage?
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        if isEnabled {
            content.workbenchHoverCard(placement: .above, maximumWidth: LitheDropdownMetrics.maximumWidth) {
                WorkbenchHoverTooltipLabel(title: Text(verbatim:
                    AgentContextUsagePresentation.details(usage, locale: locale)))
            }
        } else {
            content
        }
    }
}
