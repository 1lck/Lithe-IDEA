import SwiftUI
import LitheAgentConversationModule

enum AgentTurnStatisticsPresentation {
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
        let total = Int(max(0, seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: AgentLocalization.string("%lldh %lldm %llds", locale: locale), total / 3600, total / 60 % 60, total % 60)
        }
        if total >= 60 {
            return String(format: AgentLocalization.string("%lldm %llds", locale: locale), total / 60, total % 60)
        }
        return String(format: AgentLocalization.string("%llds", locale: locale), total)
    }

    static func input(_ usage: AgentTurnUsage, locale: Locale) -> String {
        String(format: AgentLocalization.string("Input: %@", locale: locale), usage.inputTokens.formatted(.number.locale(locale)))
    }

    static func output(_ usage: AgentTurnUsage, locale: Locale) -> String {
        String(format: AgentLocalization.string("Output: %@", locale: locale), usage.outputTokens.formatted(.number.locale(locale)))
    }

    /// `3 calls · TTFT 0.8s · 120 tok/s · non-streaming`, from proxy observations only.
    static func modelCalls(_ calls: AgentModelCallTotals, locale: Locale) -> String? {
        guard calls.callCount > 0 else { return nil }
        var parts = [String(format: AgentLocalization.string("%lld model calls", locale: locale), calls.callCount)]
        if let firstToken = calls.averageFirstToken {
            parts.append(String(format: AgentLocalization.string("TTFT %@", locale: locale), AgentSessionStatusPresentation.latency(firstToken, locale: locale)))
        }
        if let rate = calls.outputTokensPerSecond {
            parts.append(AgentSessionStatusPresentation.rate(rate, locale: locale))
        }
        if calls.nonStreamingCount > 0 {
            parts.append(calls.nonStreamingCount == calls.callCount
                         ? AgentLocalization.string("Non-streaming", locale: locale)
                         : String(format: AgentLocalization.string("%lld non-streaming", locale: locale), calls.nonStreamingCount))
        }
        return parts.joined(separator: " · ")
    }

    static func details(_ usage: AgentTurnUsage, locale: Locale) -> String {
        var lines = [AgentLocalization.string("Token counts reported by the Agent. Accounting scope depends on the Agent.", locale: locale),
                     input(usage, locale: locale), output(usage, locale: locale),
                     String(format: AgentLocalization.string("Total tokens: %@", locale: locale), usage.totalTokens.formatted(.number.locale(locale)))]
        for (label, count) in [(AgentLocalization.string("Reasoning tokens: %@", locale: locale), usage.thoughtTokens),
                               (AgentLocalization.string("Cache read tokens: %@", locale: locale), usage.cachedReadTokens),
                               (AgentLocalization.string("Cache write tokens: %@", locale: locale), usage.cachedWriteTokens)] {
            if let count { lines.append(String(format: label, count.formatted(.number.locale(locale)))) }
        }
        return lines.joined(separator: "\n")
    }
}

/// Only the visible waiting row ticks; it never republishes the conversation.
struct AgentResponseStatusRow: View {
    @Environment(\.locale) private var locale
    var responseStatus: AgentResponseStatus = .waiting
    var startedAt: ContinuousClock.Instant?
    var hasStreamingThought = false
    var retryAttempt: Int?
    var retryMaxAttempts: Int?
    var isQuiet = false
    var onContinueWaiting: () -> Void = {}
    var onStop: () -> Void = {}

    var showsQuietNotice: Bool {
        isQuiet && responseStatus != .waitingForPermission && responseStatus != .stopping
    }

    var quietNotice: String {
        AgentLocalization.string(responseStatus == .retrying
               ? "Connection recovery is taking longer. The Agent is still retrying."
               : "No recent progress has been received. The task is still active.", locale: locale)
    }

    var status: String {
        switch responseStatus {
        case .preparing: AgentLocalization.string("Preparing conversation…", locale: locale)
        case .waiting: AgentLocalization.string("Waiting for Agent response…", locale: locale)
        case .thinking: AgentLocalization.string(hasStreamingThought ? "Responding…" : "Thinking…", locale: locale)
        case .responding: AgentLocalization.string("Responding…", locale: locale)
        case .runningTools: AgentLocalization.string("Running tools…", locale: locale)
        case .waitingForPermission: AgentLocalization.string("Waiting for permission…", locale: locale)
        case .retrying:
            if let retryAttempt, let retryMaxAttempts {
                String(format: AgentLocalization.string("Reconnecting %d/%d…", locale: locale), retryAttempt, retryMaxAttempts)
            } else {
                AgentLocalization.string("Reconnecting…", locale: locale)
            }
        case .stopping: AgentLocalization.string("Stopping…", locale: locale)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).accessibilityIdentifier("agent-response-status")
                    if let startedAt {
                        let elapsed = AgentTurnStatistics(id: "waiting", startedAt: startedAt).elapsed(at: .now)
                        Text(AgentTurnStatisticsPresentation.duration(elapsed, locale: locale)).monospacedDigit()
                    }
                }
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.leading, 2)
                .help("Elapsed since sending, including tools and permission waits.")
            }
            if showsQuietNotice {
                Text(quietNotice)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-quiet-notice")
                HStack(spacing: 12) {
                    Button("Continue waiting", action: onContinueWaiting)
                    Button("Stop", action: onStop)
                }
                .buttonStyle(.plain)
                .font(LitheTheme.uiFont(size: 12))
            }
        }
    }
}

/// One frozen footer per locally observed turn, including failed or cancelled turns.
struct AgentTurnStatisticsView: View {
    let statistics: AgentTurnStatistics
    @Environment(\.locale) private var locale

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                elapsed
                if let usage = statistics.usage { tokens(usage) }
                modelCalls
            }
            VStack(alignment: .leading, spacing: 5) {
                elapsed
                if let usage = statistics.usage { tokens(usage) }
                modelCalls
            }
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-turn-statistics")
    }

    private var elapsed: some View {
        Label(String(format: AgentLocalization.string("Elapsed: %@", locale: locale),
                     AgentTurnStatisticsPresentation.duration(statistics.duration ?? 0, locale: locale)), systemImage: "clock")
            .fixedSize()
            .help("Elapsed since sending, including tools and permission waits.")
    }

    @ViewBuilder
    private var modelCalls: some View {
        if let text = AgentTurnStatisticsPresentation.modelCalls(statistics.modelCalls, locale: locale) {
            Label(text, systemImage: "bolt.horizontal")
                .fixedSize()
                .help("Model calls observed by the local proxy during this turn. TTFT is the average time to the first generated token.")
        }
    }

    private func tokens(_ usage: AgentTurnUsage) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(AgentTurnStatisticsPresentation.input(usage, locale: locale))
                Text(AgentTurnStatisticsPresentation.output(usage, locale: locale))
            }.fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                Text(AgentTurnStatisticsPresentation.input(usage, locale: locale))
                Text(AgentTurnStatisticsPresentation.output(usage, locale: locale))
            }
        }
        .help(AgentTurnStatisticsPresentation.details(usage, locale: locale))
    }
}
