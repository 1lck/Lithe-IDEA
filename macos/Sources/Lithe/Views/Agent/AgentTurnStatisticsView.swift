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

    /// `1m 2s · 25K tok`; tokens are omitted when the Agent reported none.
    static func pill(_ statistics: AgentTurnStatistics, locale: Locale) -> String {
        let elapsed = duration(statistics.duration ?? 0, locale: locale)
        guard let usage = statistics.usage else { return elapsed }
        return elapsed + " · " + AgentSessionStatusPresentation.compactTokens(usage.totalTokens, locale: locale) + " tok"
    }

    /// `14:03` for a turn that ended today, `2026-10-15 14:03` otherwise.
    static func completionTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
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

/// One frozen footer per locally observed turn, including failed or cancelled
/// turns. Copy, a compact usage pill and the completion time stay visible; the
/// full breakdown (TTFT, speed, cache) appears only in the pill's hover card.
struct AgentTurnStatisticsView: View {
    let statistics: AgentTurnStatistics
    /// The turn's final Agent reply, copied by the footer's copy button.
    var reply: String?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            if let reply, !reply.isEmpty { AgentCopyButton(text: reply, help: "Copy reply") }
            usage
            if let completedAt = statistics.completedAt {
                Text(AgentTurnStatisticsPresentation.completionTime(completedAt, locale: locale))
                    .help(completedAt.formatted(date: .complete, time: .standard))
            }
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-turn-statistics")
    }

    private var usage: some View {
        Label(AgentTurnStatisticsPresentation.pill(statistics, locale: locale), systemImage: "chart.bar")
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AgentPanelStyle.context, in: Capsule())
            .workbenchHoverCard(placement: .above, maximumWidth: AgentStatusCardMetrics.width) {
                AgentTurnStatisticsCard(statistics: statistics)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Turn usage")
            .accessibilityValue(AgentTurnStatisticsPresentation.pill(statistics, locale: locale))
    }
}

struct AgentTurnStatisticsCard: View {
    let statistics: AgentTurnStatistics
    @Environment(\.locale) private var locale

    var body: some View {
        let calls = statistics.modelCalls
        AgentStatusCard(title: "This turn", systemImage: "chart.bar",
                        trailing: statistics.usage.map { AgentSessionStatusPresentation.tokens($0.totalTokens, locale: locale) }) {
            AgentStatusRow("Elapsed", value: AgentTurnStatisticsPresentation.duration(statistics.duration ?? 0, locale: locale))
            if statistics.toolDuration > 0 {
                AgentStatusRow("Tool and permission time", value: AgentSessionStatusPresentation.latency(statistics.toolDuration, locale: locale))
            }
            if statistics.toolCallCount > 0 {
                AgentStatusRow("Tool calls", value: statistics.toolCallCount.formatted(.number.locale(locale)))
            }
            if let usage = statistics.usage {
                AgentStatusRow("Input", value: AgentSessionStatusPresentation.tokens(usage.inputTokens, locale: locale))
                AgentStatusRow("Output", value: AgentSessionStatusPresentation.tokens(usage.outputTokens, locale: locale))
                if let reasoning = usage.thoughtTokens {
                    AgentStatusRow("Reasoning", value: AgentSessionStatusPresentation.tokens(reasoning, locale: locale))
                }
                if let read = usage.cachedReadTokens {
                    AgentStatusRow("Cache read", value: AgentSessionStatusPresentation.tokens(read, locale: locale))
                }
                if let write = usage.cachedWriteTokens {
                    AgentStatusRow("Cache write", value: AgentSessionStatusPresentation.tokens(write, locale: locale))
                }
            }
            if calls.callCount > 0 {
                AgentStatusRow("Model calls (steps)", value: calls.callCount.formatted(.number.locale(locale)))
                if let firstToken = calls.averageFirstToken {
                    AgentStatusRow("Average time to first token (TTFT)", value: AgentSessionStatusPresentation.latency(firstToken, locale: locale))
                }
                if let rate = calls.outputTokensPerSecond {
                    AgentStatusRow("Output speed (TPS)", value: AgentSessionStatusPresentation.rate(rate, locale: locale))
                }
                if calls.nonStreamingCount > 0 {
                    AgentStatusRow("Non-streaming responses", value: calls.nonStreamingCount.formatted(.number.locale(locale)))
                }
            }
        } footnote: {
            if statistics.usage != nil {
                Text("Token counts reported by the Agent. Accounting scope depends on the Agent.")
            }
        }
    }
}
