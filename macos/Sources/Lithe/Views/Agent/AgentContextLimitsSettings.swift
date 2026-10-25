import SwiftUI
import LitheAgentConversationModule
import LitheCoreContracts

/// Parses and prints token counts the way people write them: `200K`, `1.5M`, `200000`.
enum AgentContextTokenText {
    /// Sizes outside this range are almost certainly typos, and an Agent may refuse them.
    static let allowed: ClosedRange<UInt64> = 10_000...10_000_000

    enum Result: Equatable {
        case cleared
        case value(UInt64)
        case invalid
    }

    static func parse(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return .cleared }
        var number = trimmed.lowercased()
        var multiplier = 1.0
        if number.hasSuffix("k") { multiplier = 1_000; number.removeLast() }
        else if number.hasSuffix("m") { multiplier = 1_000_000; number.removeLast() }
        guard let value = Double(number), value.isFinite, value > 0 else { return .invalid }
        let tokens = (value * multiplier).rounded()
        guard tokens <= Double(allowed.upperBound) else { return .invalid }
        let count = UInt64(tokens)
        return allowed.contains(count) ? .value(count) : .invalid
    }

    /// Plain digits-with-suffix text that `parse` reads back to the same number.
    static func format(_ tokens: UInt64) -> String {
        func trimmed(_ value: Double, _ suffix: String) -> String {
            let text = String(format: "%.3f", value)
            let compact = text.contains(".") ? text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression) : text
            return (compact.hasSuffix(".") ? String(compact.dropLast()) : compact) + suffix
        }
        switch tokens {
        case 1_000_000...: return tokens % 1_000 == 0 ? trimmed(Double(tokens) / 1_000_000, "M") : String(tokens)
        case 1_000...: return tokens % 100 == 0 ? trimmed(Double(tokens) / 1_000, "K") : String(tokens)
        default: return String(tokens)
        }
    }
}

/// Settings › Agents › <Agent> › Context: how much context an Agent may use and
/// where it summarizes. Both start empty (the Agent's own default, shown as the
/// placeholder once the Agent has reported it) and apply after reconnecting.
struct AgentContextLimitsSettings: View {
    @Environment(\.locale) private var locale
    let agentID: String
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    @State private var windowDraft = ""
    @State private var compactDraft = ""
    @State private var didLoad = false
    @FocusState private var windowFocused: Bool
    @FocusState private var compactFocused: Bool

    private var limits: AgentContextLimits { settings.agentContextLimits[agentID] ?? AgentContextLimits() }

    private var defaultText: String {
        settings.agentContextDefaults[agentID].map { AgentContextTokenText.format($0) }
            ?? AgentLocalization.string("not reported yet", locale: locale)
    }

    /// The Agent reports its context length, so that default is known; its compaction point is not.
    private var windowPlaceholder: String {
        String(format: AgentLocalization.string("Agent default: %@", locale: locale), defaultText)
    }

    private var compactPlaceholder: String { AgentLocalization.string("Agent default", locale: locale) }

    private var windowError: Bool { AgentContextTokenText.parse(windowDraft) == .invalid }
    private var compactError: Bool { AgentContextTokenText.parse(compactDraft) == .invalid }

    private var thresholdAboveWindow: Bool {
        guard case .value(let window) = AgentContextTokenText.parse(windowDraft),
              case .value(let compact) = AgentContextTokenText.parse(compactDraft) else { return false }
        return compact > window
    }

    /// The running connection still uses the limits it started with.
    private var needsReconnect: Bool {
        guard let feature = model.agentConversationFeatureIfActive, feature.agents.contains(where: { $0.id == agentID }) else { return false }
        let connection = feature.connection(for: agentID)
        return connection.hasActiveConnection && connection.contextLimits != limits
    }

    var body: some View {
        LitheSettingsSection("Context") {
            LitheSettingsRow("Context length",
                info: "Tokens of context this Agent may use. The context ring reads as full at this size. Codex applies it as its context window; for Claude Code the model decides its own size, so this sets where it compacts when no threshold is given. Leave empty for the Agent's default. Applies after reconnecting.") {
                field($windowDraft, placeholder: windowPlaceholder, focus: $windowFocused, isInvalid: windowError)
                resetButton(for: .window)
            }
            LitheSettingsRow("Auto-compact at",
                info: "Tokens at which the Agent summarizes its context automatically. Lower it to cap what each request costs. Leave empty for the Agent's default. Applies after reconnecting.") {
                field($compactDraft, placeholder: compactPlaceholder, focus: $compactFocused,
                      isInvalid: compactError || thresholdAboveWindow)
                resetButton(for: .compact)
            }
            if windowError || compactError {
                Text("Enter a size such as 200K or 1M, between 10K and 10M.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
            } else if thresholdAboveWindow {
                Text("Auto-compact must not be larger than the context length.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error)
            } else if needsReconnect {
                Text("Reconnect the Agent to apply these limits.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning)
            }
        }
        .onAppear { loadDrafts() }
        .onChange(of: windowFocused) { focused in if !focused { commit() } }
        .onChange(of: compactFocused) { focused in if !focused { commit() } }
        .onDisappear { commit() }
    }

    private func field(_ text: Binding<String>, placeholder: String, focus: FocusState<Bool>.Binding,
                       isInvalid: Bool) -> some View {
        LitheTextField(verbatim: placeholder, text: text, focus: focus)
            .frame(width: 190)
            .onSubmit { commit() }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isInvalid ? LitheTheme.error : .clear, lineWidth: 1))
    }

    private enum Kind { case window, compact }

    @ViewBuilder
    private func resetButton(for kind: Kind) -> some View {
        let isSet = kind == .window ? limits.windowTokens != nil : limits.autoCompactTokens != nil
        if isSet {
            Button("Reset") {
                if kind == .window { windowDraft = "" } else { compactDraft = "" }
                commit()
            }
            .buttonStyle(.litheNoPress)
            .foregroundStyle(LitheTheme.accent)
            .lithePointer()
        }
    }

    private func loadDrafts() {
        guard !didLoad else { return }
        didLoad = true
        windowDraft = limits.windowTokens.map { AgentContextTokenText.format($0) } ?? ""
        compactDraft = limits.autoCompactTokens.map { AgentContextTokenText.format($0) } ?? ""
    }

    /// Saves what parses; an empty field clears its limit and an invalid one keeps the last good value.
    private func commit() {
        guard didLoad else { return }
        var next = limits
        switch AgentContextTokenText.parse(windowDraft) {
        case .cleared: next.windowTokens = nil
        case .value(let tokens): next.windowTokens = tokens
        case .invalid: break
        }
        switch AgentContextTokenText.parse(compactDraft) {
        case .cleared: next.autoCompactTokens = nil
        case .value(let tokens): next.autoCompactTokens = tokens
        case .invalid: break
        }
        if let window = next.windowTokens, let compact = next.autoCompactTokens, compact > window { return }
        guard next != limits else { return }
        if next.isEmpty { settings.agentContextLimits[agentID] = nil } else { settings.agentContextLimits[agentID] = next }
    }
}
