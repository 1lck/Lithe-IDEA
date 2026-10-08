import SwiftUI
import LitheAgentConversationModule

enum AgentTurnStatisticsPresentation {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
        let total = Int(max(0, seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: String(localized: "%lldh %lldm %llds"), total / 3600, total / 60 % 60, total % 60)
        }
        if total >= 60 {
            return String(format: String(localized: "%lldm %llds"), total / 60, total % 60)
        }
        return String(format: String(localized: "%llds"), total)
    }

    static func input(_ usage: AgentTurnUsage, locale: Locale) -> String {
        String(format: String(localized: "Input: %@"), usage.inputTokens.formatted(.number.locale(locale)))
    }

    static func output(_ usage: AgentTurnUsage, locale: Locale) -> String {
        String(format: String(localized: "Output: %@"), usage.outputTokens.formatted(.number.locale(locale)))
    }

    static func details(_ usage: AgentTurnUsage, locale: Locale) -> String {
        var lines = [String(localized: "Token counts reported by the Agent. Accounting scope depends on the Agent."),
                     input(usage, locale: locale), output(usage, locale: locale),
                     String(format: String(localized: "Total tokens: %@"), usage.totalTokens.formatted(.number.locale(locale)))]
        for (label, count) in [(String(localized: "Reasoning tokens: %@"), usage.thoughtTokens),
                               (String(localized: "Cache read tokens: %@"), usage.cachedReadTokens),
                               (String(localized: "Cache write tokens: %@"), usage.cachedWriteTokens)] {
            if let count { lines.append(String(format: label, count.formatted(.number.locale(locale)))) }
        }
        return lines.joined(separator: "\n")
    }
}

/// Only the visible waiting row ticks; it never republishes the conversation.
struct AgentResponseStatusRow: View {
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
        String(localized: responseStatus == .retrying
               ? "Connection recovery is taking longer. The Agent is still retrying."
               : "No recent progress has been received. The task is still active.")
    }

    var status: String {
        switch responseStatus {
        case .preparing: String(localized: "Preparing conversation…")
        case .waiting: String(localized: "Waiting for Agent response…")
        case .thinking: String(localized: hasStreamingThought ? "Responding…" : "Thinking…")
        case .responding: String(localized: "Responding…")
        case .runningTools: String(localized: "Running tools…")
        case .waitingForPermission: String(localized: "Waiting for permission…")
        case .retrying:
            if let retryAttempt, let retryMaxAttempts {
                String(format: String(localized: "Reconnecting %d/%d…"), retryAttempt, retryMaxAttempts)
            } else {
                String(localized: "Reconnecting…")
            }
        case .stopping: String(localized: "Stopping…")
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
                        Text(AgentTurnStatisticsPresentation.duration(elapsed)).monospacedDigit()
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
            }
            VStack(alignment: .leading, spacing: 5) {
                elapsed
                if let usage = statistics.usage { tokens(usage) }
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
        Label(String(format: String(localized: "Elapsed: %@"),
                     AgentTurnStatisticsPresentation.duration(statistics.duration ?? 0)), systemImage: "clock")
            .fixedSize()
            .help("Elapsed since sending, including tools and permission waits.")
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
