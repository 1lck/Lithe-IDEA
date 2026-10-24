import SwiftUI
import LitheAgentConversationModule

/// Presentation of one account's last reported usage windows. Pace compares the
/// share of the window already used with the share of its time already elapsed.
enum AgentAccountUsagePresentation {
    /// Percentage points used beyond (positive) or below (negative) an even burn rate.
    static func pace(_ window: AgentSubscriptionQuota.Window, now: Date) -> Double? {
        guard let used = window.usedPercent, let reset = window.resetsAt, window.limitSeconds > 0 else { return nil }
        let remaining = Double(reset) - now.timeIntervalSince1970
        guard remaining > 0 else { return nil }
        let elapsed = 1 - min(remaining / Double(window.limitSeconds), 1)
        return used - elapsed * 100
    }

    static func signedPercent(_ value: Double, locale: Locale) -> String {
        let text = abs(value / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return (value < 0 ? "−" : "+") + text
    }

    /// Only the two windows an account shows; per-model windows stay out of the card.
    static func visibleWindows(_ quota: AgentSubscriptionQuota?) -> [AgentSubscriptionQuota.Window] {
        AgentSubscriptionQuotaPresentation.windows(quota).filter {
            $0.limitSeconds == AgentSubscriptionQuotaPresentation.fiveHours
                || $0.limitSeconds == AgentSubscriptionQuotaPresentation.sevenDays
        }
    }
}

/// Accounts of an Agent's official subscription. Each is an isolated CLI
/// configuration directory; Lithe stores names and paths, never credentials.
struct AgentAccountsSection: View {
    @Environment(\.locale) private var locale
    let agentID: String
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var errorMessage: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var removal: AgentAccountProfile?
    /// Set while a background sign-in runs; the browser flow belongs to the CLI.
    @State private var signingIn: String?

    private struct Entry: Identifiable {
        let id: String
        let profile: AgentAccountProfile?
        var isDefault: Bool { profile == nil }
    }

    private var entries: [Entry] {
        [Entry(id: AppSettings.defaultAgentAccountKey(agentID), profile: nil)]
            + settings.agentAccounts(for: agentID).map { Entry(id: "\(agentID):\($0.id.uuidString)", profile: $0) }
    }

    var body: some View {
        LitheSettingsSection(title: "Subscription accounts", accessory: {
            LitheInfoTip("Each account is a separate configuration folder of the official CLI. Sign-in runs the CLI's own login command in the background and opens your browser, so Lithe never reads or copies credentials. Switching restarts this project's connection for this Agent and is refused while a reply or permission request is pending. Lithe never switches accounts by itself when a limit is reached.")
        }) {
            ForEach(entries) { entry in
                accountCard(entry)
            }
            HStack {
                Button { signIn(entryID: "new") { try await model.addAgentAccount(agentID: agentID) } } label: {
                    Label("Add another account", systemImage: "plus")
                }
                .buttonStyle(LitheActionButtonStyle())
                .disabled(signingIn != nil)
                if signingIn != nil {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser sign-in…").font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
                    Button("Cancel") { actionTask?.cancel() }.buttonStyle(LitheActionButtonStyle())
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            if let errorMessage { AgentSettingsIssue(errorMessage) }
        }
        .disabled(model.isChangingAgentProvider)
        .alert("Remove account", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Remove", role: .destructive) {
                guard let profile = removal else { return }
                removal = nil
                perform { try await model.removeAgentAccount(profile.id) }
            }
        } message: {
            Text("Remove this account from Lithe? Its sign-in folder is left on disk untouched.")
        }
        .onDisappear { actionTask?.cancel() }
    }

    private func accountCard(_ entry: Entry) -> some View {
        let preferred = entry.profile?.id == settings.preferredAgentAccountIDs[agentID]
        let snapshot = settings.agentAccountSnapshots[entry.id]
        let title = snapshot?.email ?? entry.profile?.name ?? AgentLocalization.string("Default account", locale: locale)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: preferred ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(preferred ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(verbatim: title).font(LitheTheme.uiFont(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let plan = snapshot?.plan { badge(plan) }
                if preferred { badge(AgentLocalization.string("Preferred", locale: locale)) }
                Spacer(minLength: 8)
                if !preferred {
                    Button("Set as preferred") {
                        perform { try await model.setPreferredAgentAccount(entry.profile?.id, agentID: agentID) }
                    }
                    .buttonStyle(LitheActionButtonStyle())
                }
                if let profile = entry.profile {
                    Button("Sign in again") { signIn(entryID: entry.id) { try await model.signInAgentAccount(profile.id) } }
                        .buttonStyle(LitheActionButtonStyle())
                        .disabled(signingIn != nil)
                    Button { removal = profile } label: { Image(systemName: "trash") }
                        .litheIconButton().help("Remove account")
                }
            }
            usage(snapshot)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("agent-account-\(entry.id)")
    }

    private func badge(_ text: String) -> some View {
        Text(verbatim: text).font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
    }

    @ViewBuilder
    private func usage(_ snapshot: AgentAccountSnapshot?) -> some View {
        let now = Date()
        let windows = AgentAccountUsagePresentation.visibleWindows(snapshot?.quota)
        if windows.isEmpty {
            HStack(spacing: 4) {
                AgentSettingsHint("Usage appears after the next reply.")
                usageInfoTip
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                ForEach(windows) { window in windowColumn(window, now: now) }
            }
            if let snapshot {
                HStack(spacing: 4) {
                    Text(String(format: AgentLocalization.string("As of %@; not refreshed by Lithe.", locale: locale),
                                snapshot.observedAt.formatted(.dateTime.year().month().day().hour().minute().second().locale(locale))))
                        .font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.warning)
                    usageInfoTip
                }
            }
        }
    }

    /// Explains when the numbers change, so an old value is not mistaken for a live one.
    private var usageInfoTip: some View {
        LitheInfoTip("Usage is whatever the Agent last reported. Claude Code reports it while a reply runs; Codex is also refreshed about once a minute while the Agent panel is open. Lithe never queries the account itself, so a value can be out of date, and an account you are not using keeps its last values until you switch back. A window that has already reset is shown without a reset time or pace.")
    }

    private func windowColumn(_ window: AgentSubscriptionQuota.Window, now: Date) -> some View {
        let expired = window.resetsAt.map { Double($0) <= now.timeIntervalSince1970 } ?? false
        let color = AgentSubscriptionQuotaPresentation.level(window.usedPercent, stale: expired).color
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.limitSeconds == AgentSubscriptionQuotaPresentation.fiveHours ? LocalizedStringKey("5 hours") : LocalizedStringKey("7 days"))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 8)
                Text(String(format: AgentLocalization.string("Used %@", locale: locale),
                            AgentSubscriptionQuotaPresentation.percentage(window, locale: locale)))
                    .foregroundStyle(color).monospacedDigit()
            }
            .font(LitheTheme.uiFont(size: 11))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LitheTheme.secondaryText.opacity(0.2))
                    if let used = window.usedPercent {
                        Capsule().fill(color).frame(width: geometry.size.width * min(max(used / 100, 0), 1))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            if let reset = window.resetsAt, !expired {
                let date = Date(timeIntervalSince1970: Double(reset))
                HStack(spacing: 4) {
                    Text(String(format: AgentLocalization.string("Resets %@", locale: locale),
                                date.formatted(.dateTime.month().day().hour().minute().locale(locale))))
                    Text(verbatim: "·")
                    Text(verbatim: Self.relative(date, now: now, locale: locale))
                    if let pace = AgentAccountUsagePresentation.pace(window, now: now) {
                        Text(verbatim: "·")
                        Text(String(format: AgentLocalization.string("Pace %@", locale: locale),
                                    AgentAccountUsagePresentation.signedPercent(pace, locale: locale)))
                            .foregroundStyle(pace > 0 ? LitheTheme.warning : LitheTheme.secondaryText)
                    }
                }
                .font(LitheTheme.uiFont(size: 10.5)).foregroundStyle(LitheTheme.tertiaryText).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Sign-ins wait for the browser, so they show progress and can be cancelled.
    private func signIn(entryID: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard actionTask == nil else { return }
        signingIn = entryID
        actionTask = Task { @MainActor in
            defer { actionTask = nil; signingIn = nil }
            do { try await action(); errorMessage = nil }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard actionTask == nil else { return }
        actionTask = Task { @MainActor in
            defer { actionTask = nil }
            do { try await action(); errorMessage = nil }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
