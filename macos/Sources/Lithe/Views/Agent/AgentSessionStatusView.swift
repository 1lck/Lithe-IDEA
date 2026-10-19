import SwiftUI
import LitheAgentConversationModule

enum AgentSessionStatusPresentation {
    /// `43.6K` / `3.7M`, matching the compact counters in the status bar.
    static func compactTokens(_ count: UInt64, locale: Locale) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(locale)
        switch count {
        case 1_000_000...: return (Double(count) / 1_000_000).formatted(format) + "M"
        case 1_000...: return (Double(count) / 1_000).formatted(format) + "K"
        default: return count.formatted(.number.locale(locale))
        }
    }

    static func tokens(_ count: UInt64, locale: Locale) -> String {
        String(format: AgentLocalization.string("%@ tok", locale: locale), count.formatted(.number.locale(locale)))
    }

    static func percent(_ fraction: Double, locale: Locale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    static func rate(_ tokensPerSecond: Double, locale: Locale) -> String {
        String(format: AgentLocalization.string("%@ tok/s", locale: locale),
               tokensPerSecond.formatted(.number.precision(.fractionLength(0)).locale(locale)))
    }

    static func latency(_ seconds: TimeInterval, locale: Locale) -> String {
        if seconds < 10 {
            let value = seconds.formatted(.number.precision(.fractionLength(1)).locale(locale))
            return String(format: AgentLocalization.string("%@s", locale: locale), value)
        }
        return AgentTurnStatisticsPresentation.duration(seconds, locale: locale)
    }

    /// `7 turns 54 steps · 232 tok/s`; steps and speed require observed model calls.
    static func summary(_ statistics: AgentSessionStatistics, locale: Locale, showsRate: Bool = true) -> String {
        var text = String(format: AgentLocalization.string("%lld turns", locale: locale), statistics.turnCount)
        if let calls = statistics.modelCalls {
            text += " " + String(format: AgentLocalization.string("%lld steps", locale: locale), calls.callCount)
            if showsRate, let rate = calls.outputTokensPerSecond { text += " · " + self.rate(rate, locale: locale) }
        }
        return text
    }

    /// `≥` marks a lower bound when some observed calls returned no usage.
    static func lowerBound(_ tokens: AgentSessionTokens) -> String {
        tokens.callsMissingUsage > 0 ? "≥" : ""
    }

    static func tokenSummary(_ tokens: AgentSessionTokens, locale: Locale) -> String {
        var text = lowerBound(tokens) + compactTokens(tokens.totalTokens, locale: locale) + " tok"
        if let hit = tokens.cacheHitRate {
            text += " · " + String(format: AgentLocalization.string("Cache hit %@", locale: locale), percent(hit, locale: locale))
        }
        return text
    }
}

/// Session status entries shown before the context ring in the composer bar.
/// The ring appears only after the Agent's first usage report.
struct AgentSessionStatusView: View {
    @Environment(\.locale) private var locale
    let statistics: AgentSessionStatistics
    let contextUsage: AgentContextUsage?
    var showsContext = true

    var body: some View {
        // Narrow panels first drop the speed (kept in the hover card), then the
        // session summary, then token usage; context occupancy stays once reported.
        ViewThatFits(in: .horizontal) {
            entries(showsSession: true, showsRate: true, showsTokens: true)
            entries(showsSession: true, showsRate: false, showsTokens: true)
            entries(showsSession: false, showsRate: false, showsTokens: true)
            entries(showsSession: false, showsRate: false, showsTokens: false)
        }
    }

    private func entries(showsSession: Bool, showsRate: Bool, showsTokens: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSession && statistics.turnCount > 0 {
                AgentSessionSummaryView(statistics: statistics, showsRate: showsRate)
            }
            if showsTokens, let tokens = statistics.tokens {
                AgentTokenUsageView(tokens: tokens)
            }
            if showsContext {
                AgentContextUsageView(usage: contextUsage, composition: statistics.modelCalls?.latestContext,
                                      isHiddenUntilReported: true)
            }
        }
        .fixedSize()
    }
}

struct AgentSessionSummaryView: View {
    let statistics: AgentSessionStatistics
    var showsRate = true
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(AgentSessionStatusPresentation.summary(statistics, locale: locale, showsRate: showsRate))
        }
            .lineLimit(1)
            .monospacedDigit()
            .padding(.vertical, 4)
            .fixedSize()
            .workbenchHoverCard(placement: .above, maximumWidth: AgentStatusCardMetrics.width) {
                AgentSessionSummaryCard(statistics: statistics)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session statistics")
            .accessibilityValue(AgentSessionStatusPresentation.summary(statistics, locale: locale))
            .accessibilityIdentifier("agent-session-statistics")
    }
}

struct AgentSessionSummaryCard: View {
    let statistics: AgentSessionStatistics
    @Environment(\.locale) private var locale

    var body: some View {
        AgentStatusCard(title: "Session statistics", systemImage: "gauge.with.dots.needle.33percent") {
            AgentStatusRow("Turns", value: statistics.turnCount.formatted(.number.locale(locale)))
            if let calls = statistics.modelCalls {
                AgentStatusRow("Model calls (steps)", value: callCount(calls))
            }
            AgentStatusRow("Tool calls", value: statistics.toolCallCount.formatted(.number.locale(locale)))
            if let calls = statistics.modelCalls {
                AgentStatusRow("Model time", value: AgentTurnStatisticsPresentation.duration(calls.duration, locale: locale))
            }
            AgentStatusRow("Tool and permission time", value: AgentTurnStatisticsPresentation.duration(statistics.toolDuration, locale: locale))
            if let calls = statistics.modelCalls {
                AgentStatusRow("Average time to first token (TTFT)",
                               value: calls.averageFirstToken.map { AgentSessionStatusPresentation.latency($0, locale: locale) } ?? "—")
                AgentStatusRow("Output speed (TPS)",
                               value: calls.outputTokensPerSecond.map { AgentSessionStatusPresentation.rate($0, locale: locale) } ?? "—")
                if calls.nonStreamingCount > 0 {
                    AgentStatusRow("Non-streaming responses", value: calls.nonStreamingCount.formatted(.number.locale(locale)))
                }
            }
        } footnote: {
            if statistics.modelCalls == nil {
                Text("Turn on Model call statistics in Agent settings and reconnect to see model calls, time to first token and output speed.")
            }
        }
    }

    private func callCount(_ calls: AgentModelCallTotals) -> String {
        let count = calls.callCount.formatted(.number.locale(locale))
        guard calls.failedCount > 0 else { return count }
        return String(format: AgentLocalization.string("%@ (%@ failed)", locale: locale), count, calls.failedCount.formatted(.number.locale(locale)))
    }
}

struct AgentTokenUsageView: View {
    let tokens: AgentSessionTokens
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cylinder.split.1x2")
            Text(AgentSessionStatusPresentation.tokenSummary(tokens, locale: locale))
        }
            .lineLimit(1)
            .monospacedDigit()
            .padding(.vertical, 4)
            .fixedSize()
            .workbenchHoverCard(placement: .above, maximumWidth: AgentStatusCardMetrics.width) {
                AgentTokenUsageCard(tokens: tokens)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Token usage")
            .accessibilityValue(AgentSessionStatusPresentation.tokenSummary(tokens, locale: locale))
            .accessibilityIdentifier("agent-token-usage")
    }
}

struct AgentTokenUsageCard: View {
    let tokens: AgentSessionTokens
    @Environment(\.locale) private var locale

    var body: some View {
        AgentStatusCard(title: "Token usage", systemImage: "cylinder.split.1x2",
                        trailing: AgentSessionStatusPresentation.lowerBound(tokens)
                            + AgentSessionStatusPresentation.tokens(tokens.totalTokens, locale: locale)) {
            AgentStatusRow("Cache hit", value: tokens.cacheHitRate.map { AgentSessionStatusPresentation.percent($0, locale: locale) } ?? "—")
            AgentStatusRow("Uncached input", value: AgentSessionStatusPresentation.tokens(tokens.uncachedInputTokens, locale: locale))
            AgentStatusRow("Cache read", value: AgentSessionStatusPresentation.tokens(tokens.cacheReadTokens, locale: locale))
            if tokens.cacheWriteTokens > 0 {
                AgentStatusRow("Cache write", value: AgentSessionStatusPresentation.tokens(tokens.cacheWriteTokens, locale: locale))
            }
            AgentStatusRow("Output", value: AgentSessionStatusPresentation.tokens(tokens.outputTokens, locale: locale))
            if let reasoning = tokens.reasoningTokens {
                AgentStatusRow("Reasoning", value: AgentSessionStatusPresentation.tokens(reasoning, locale: locale))
            }
        } footnote: {
            if tokens.callsMissingUsage > 0 {
                Text(String(format: AgentLocalization.string("%lld requests returned no usage, so these totals are a lower bound.", locale: locale),
                            tokens.callsMissingUsage))
            } else if tokens.source == .latestAgentTurn {
                Text("Latest turn as reported by the Agent; its accounting scope depends on the Agent. Turn on Model call statistics for session totals.")
            }
        }
    }
}

/// Context occupancy split into the parts of the latest request. Shares are
/// measured against the context window, so free space stays visible.
struct AgentContextBreakdown {
    let usage: AgentContextUsage?
    let composition: AgentModelCall.Context?

    enum Segment: CaseIterable {
        case systemPrompt, tools, messages, mcpTools

        var title: LocalizedStringKey {
            switch self {
            case .systemPrompt: "System prompt"
            case .tools: "Tool definitions"
            case .mcpTools: "MCP tools"
            case .messages: "Messages"
            }
        }

        var color: Color {
            switch self {
            case .systemPrompt: AgentPanelStyle.focus
            case .tools: LitheTheme.success
            case .messages: LitheTheme.warning
            case .mcpTools: AgentPanelStyle.versionAccent
            }
        }

        func tokens(_ context: AgentModelCall.Context) -> UInt64 {
            switch self {
            case .systemPrompt: context.systemPromptTokens
            case .tools: context.toolTokens
            case .mcpTools: context.mcpToolTokens
            case .messages: context.messageTokens
            }
        }

        func toolCount(_ context: AgentModelCall.Context) -> Int? {
            switch self {
            case .tools: context.toolCount
            case .mcpTools: context.mcpToolCount
            default: nil
            }
        }
    }

    var hasFigures: Bool { usage != nil || composition != nil }
    // Request size alone cannot establish the model's context window.
    var total: UInt64 { usage?.capacityTokens ?? 0 }
    var freeTokens: UInt64? {
        usage.map { $0.capacityTokens > $0.usedTokens ? $0.capacityTokens - $0.usedTokens : 0 }
    }

    /// Segments with a size, MCP tools only when the request carried any.
    var segments: [Segment] {
        guard let composition else { return [] }
        return Segment.allCases.filter { segment in
            segment != .mcpTools || composition.mcpToolCount > 0
        }
    }

    func share(_ tokens: UInt64, locale: Locale) -> String {
        guard total > 0 else { return "—" }
        return (Double(tokens) / Double(total))
            .formatted(.percent.precision(.fractionLength(1)).locale(locale))
    }

    func capacity(locale: Locale) -> String? {
        guard let usage else {
            return composition.map { "~" + AgentSessionStatusPresentation.compactTokens($0.totalTokens, locale: locale) }
        }
        return AgentContextUsagePresentation.tokens(usage.usedTokens, locale: locale) + " / "
            + AgentContextUsagePresentation.tokens(usage.capacityTokens, locale: locale)
    }

    /// Segments are drawn against the window size so free space stays visible.
    var bar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if let composition, total > 0 {
                    ForEach(Segment.allCases, id: \.self) { segment in
                        let fraction = Double(segment.tokens(composition)) / Double(total)
                        if fraction > 0 {
                            let width = geometry.size.width * min(fraction, 1)
                            Rectangle().fill(segment.color)
                                .overlay(alignment: .trailing) {
                                    if width >= 2 { AgentPanelStyle.canvas.frame(width: 1) }
                                }
                                .frame(width: width)
                        }
                    }
                } else if let usage {
                    Rectangle().fill(AgentPanelStyle.focus)
                        .frame(width: geometry.size.width * min(usage.fraction, 1))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .background(AgentPanelStyle.border)
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    func rows(locale: Locale) -> some View {
        if let composition {
            ForEach(segments, id: \.self) { segment in
                let tokens = segment.tokens(composition)
                AgentStatusRow(segment.title,
                               value: "~" + AgentSessionStatusPresentation.compactTokens(tokens, locale: locale),
                               share: share(tokens, locale: locale), swatch: segment.color)
            }
        }
        if let freeTokens {
            AgentStatusRow("Free space", value: AgentSessionStatusPresentation.compactTokens(freeTokens, locale: locale),
                           share: share(freeTokens, locale: locale), swatch: AgentPanelStyle.border)
        }
    }

    @ViewBuilder
    func footnote(bundle: Bundle = .main) -> some View {
        if composition != nil {
            estimationNote(bundle: bundle)
        } else if usage == nil {
            Text("The Agent has not reported context usage yet.", bundle: bundle)
        } else {
            Text("Turn on Model call statistics in Agent settings and reconnect to see the system prompt, tool definitions and messages.", bundle: bundle)
        }
    }

    func estimationNote(bundle: Bundle = .main) -> Text {
        composition?.scaledToUsage == true
            ? Text("Estimated from the size of the latest request and scaled to the provider's input tokens.", bundle: bundle)
            : Text("Estimated from the size of the latest request.", bundle: bundle)
    }
}

/// Context breakdown shown when hovering the context ring.
struct AgentContextUsageCard: View {
    let usage: AgentContextUsage?
    let composition: AgentModelCall.Context?
    @Environment(\.locale) private var locale

    private var breakdown: AgentContextBreakdown { AgentContextBreakdown(usage: usage, composition: composition) }

    private var title: String {
        String(format: AgentLocalization.string("Context used %@", locale: locale),
               usage.map { AgentContextUsagePresentation.percentage($0, locale: locale) } ?? "—")
    }

    var body: some View {
        AgentStatusCard(verbatimTitle: title, trailing: breakdown.capacity(locale: locale), compact: !breakdown.hasFigures) {
            if breakdown.hasFigures { breakdown.bar }
            breakdown.rows(locale: locale)
        } footnote: {
            breakdown.footnote()
        }
    }
}

/// Shared context summary for the send-button popup and session details.
/// Only the four observed request categories are shown; absent figures stay unknown.
struct AgentContextPanel: View {
    static let popoverWidth: CGFloat = 300

    let usage: AgentContextUsage?
    let composition: AgentModelCall.Context?
    var onClose: (() -> Void)?
    var bundle: Bundle = .main
    @Environment(\.locale) private var locale

    private var breakdown: AgentContextBreakdown { AgentContextBreakdown(usage: usage, composition: composition) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Context usage", bundle: bundle).font(LitheTheme.uiFont(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if let onClose {
                    Button(action: onClose) {
                        LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                      fallbackSystemImage: "xmark", preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .accessibilityLabel(Text("Close", bundle: bundle))
                    .accessibilityIdentifier("agent-context-close")
                }
            }
            .foregroundStyle(LitheTheme.primaryText)
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { percentage; capacity }
                    VStack(alignment: .leading, spacing: 4) { percentage; capacity }
                }
                breakdown.bar
            }
            VStack(spacing: 12) {
                ForEach(AgentContextBreakdown.Segment.allCases, id: \.self) { segment in
                    legendRow(segment)
                }
            }
            if composition == nil {
                Divider().overlay(LitheTheme.divider)
                Group {
                    if usage == nil {
                        breakdown.footnote(bundle: bundle)

                    } else {
                        Text("Turn on Model call statistics, reconnect and send a message to see the breakdown.", bundle: bundle)
                    }
                }
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(AgentPanelStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .foregroundStyle(LitheTheme.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent-context-panel")
    }

    private var percentage: some View {
        Text(verbatim: AgentContextUsagePresentation.percentage(usage, locale: locale, precise: true))
            .font(LitheTheme.uiFont(size: 24, weight: .semibold)).monospacedDigit().fixedSize()
    }

    @ViewBuilder
    private var capacity: some View {
        if let usage {
            let counts = AgentContextUsagePresentation.tokens(usage.usedTokens, locale: locale) + " / "
                + AgentContextUsagePresentation.tokens(usage.capacityTokens, locale: locale)
            Text(verbatim: String(format: AgentLocalization.string("Used %@", locale: locale, bundle: bundle), counts))
                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                .monospacedDigit().fixedSize()
        }
    }

    private func legendRow(_ segment: AgentContextBreakdown.Segment) -> some View {
        HStack(spacing: 8) {
            Circle().fill(segment.color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(segment.title, bundle: bundle).lineLimit(1)
            if let composition, let count = segment.toolCount(composition) {
                Text(verbatim: "(\(count.formatted(.number.locale(locale))))")
                    .font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(AgentPanelStyle.muted)
            }
            Spacer(minLength: 8)
            Text(verbatim: usage == nil ? "—" : composition.map { "~" + breakdown.share(segment.tokens($0), locale: locale) } ?? "—")
                .foregroundStyle(AgentPanelStyle.secondary).monospacedDigit().fixedSize()
        }
        .workbenchHoverCard(placement: .above, maximumWidth: LitheDropdownMetrics.maximumWidth) {
            if let composition {
                WorkbenchHoverTooltipLabel(title: Text(verbatim: "~"
                    + AgentSessionStatusPresentation.tokens(segment.tokens(composition), locale: locale) + "\n")
                    + breakdown.estimationNote(bundle: bundle))
            } else {
                WorkbenchHoverTooltipLabel(title: Text("Breakdown unavailable", bundle: bundle))
            }
        }
    }
}

enum AgentStatusCardMetrics {
    static let width: CGFloat = 300
}

private struct AgentStatusCardInlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Status cards normally render as hover cards. The editor conversation's
    /// details column embeds the same cards inline at its own width.
    var agentStatusCardIsInline: Bool {
        get { self[AgentStatusCardInlineKey.self] }
        set { self[AgentStatusCardInlineKey.self] = newValue }
    }
}

/// Shared surface of the status hover cards.
struct AgentStatusCard<Rows: View, Footnote: View>: View {
    @Environment(\.locale) private var locale
    @Environment(\.agentStatusCardIsInline) private var isInline

    private let title: Text
    private let systemImage: String?
    private let trailing: String?
    private let rows: Rows
    private let footnote: Footnote
    private let compact: Bool

    init(title: LocalizedStringKey, systemImage: String? = nil, trailing: String? = nil,
         @ViewBuilder rows: () -> Rows, @ViewBuilder footnote: () -> Footnote) {
        compact = false
        self.title = Text(title)
        self.systemImage = systemImage
        self.trailing = trailing
        self.rows = rows()
        self.footnote = footnote()
    }

    init(verbatimTitle: String, trailing: String?, compact: Bool = false, @ViewBuilder rows: () -> Rows, @ViewBuilder footnote: () -> Footnote) {
        self.compact = compact
        title = Text(verbatim: verbatimTitle)
        systemImage = nil
        self.trailing = trailing
        self.rows = rows()
        self.footnote = footnote()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                title.font(LitheTheme.uiFont(size: compact ? 11 : 12, weight: .semibold))
                Spacer(minLength: 12)
                if let trailing {
                    Text(verbatim: trailing).font(LitheTheme.uiFont(size: compact ? 11 : 12, weight: .semibold)).monospacedDigit()
                }
            }
            .foregroundStyle(LitheTheme.HoverTooltip.foreground)
            Divider().overlay(LitheTheme.divider)
            VStack(alignment: .leading, spacing: 6) { rows }
            footnote
                .font(LitheTheme.uiFont(size: compact ? 10 : 10.5))
                .foregroundStyle(LitheTheme.HoverTooltip.infoForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(LitheTheme.uiFont(size: 12))
        .modifier(AgentStatusCardSurface(isInline: isInline, compact: compact))
    }
}

private struct AgentStatusCardSurface: ViewModifier {
    let isInline: Bool
    let compact: Bool

    func body(content: Content) -> some View {
        if isInline {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .padding(compact ? 8 : 12)
                .frame(width: compact ? 240 : AgentStatusCardMetrics.width, alignment: .leading)
                .litheHoverTooltipSurface()
        }
    }
}

extension AgentStatusCard where Footnote == EmptyView {
    init(title: LocalizedStringKey, systemImage: String? = nil, trailing: String? = nil, @ViewBuilder rows: () -> Rows) {
        self.init(title: title, systemImage: systemImage, trailing: trailing, rows: rows) { EmptyView() }
    }
}

struct AgentStatusRow: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringKey
    let value: String
    var share: String?
    var swatch: Color?

    init(_ title: LocalizedStringKey, value: String, share: String? = nil, swatch: Color? = nil) {
        self.title = title
        self.value = value
        self.share = share
        self.swatch = swatch
    }

    var body: some View {
        HStack(spacing: 6) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9)
            }
            Text(title).foregroundStyle(AgentPanelStyle.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text(verbatim: value).foregroundStyle(share == nil ? LitheTheme.HoverTooltip.foreground : AgentPanelStyle.secondary)
                .monospacedDigit().lineLimit(1)
            if let share {
                Text(verbatim: share).foregroundStyle(LitheTheme.HoverTooltip.foreground)
                    .monospacedDigit().lineLimit(1)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}
