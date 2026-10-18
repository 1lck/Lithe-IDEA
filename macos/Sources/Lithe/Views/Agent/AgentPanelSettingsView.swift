import AppKit
import SwiftUI
import LitheCoreContracts

/// Settings page in the main Settings window. Each agent can follow local CLI configuration or a custom provider for its
/// endpoint, model and API key. Node.js remains user-managed; CLI updates use
/// their installation owner, while ACP adapters are installed with npm.
struct AgentPanelSettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var feature: AgentManagementFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("Agents").font(LitheTheme.uiFont(size: 16, weight: .semibold))
                LitheInfoTip("Install ACP adapters, check the runtime, and manage local or custom providers.")
            }
            AgentsManagementPage(model: model, settings: settings, feature: feature)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task { await feature.refresh() }
    }
}

// MARK: - Agents page

/// Flat settings form with the same Agent selection as the conversation panel.
private struct AgentsManagementPage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var feature: AgentManagementFeatureModel
    private var selectedID: String? { model.selectedAgentConversationID }

    private enum Entry: Hashable {
        case agent(String)
        case custom
    }

    private var agents: [AgentCatalogStatus] { feature.status?.agents ?? [] }

    private var selectedEntry: Entry {
        if let selectedID, agents.contains(where: { $0.id == selectedID }) { return .agent(selectedID) }
        if selectedID == AgentConfiguration.customAgentID { return .custom }
        return agents.first.map { .agent($0.id) } ?? .custom
    }

    var body: some View {
        LitheSettingsSection("Features") {
            featureRow
            statisticsRow
        }
        agentPicker
        checkFeedback
        switch selectedEntry {
        case .agent(let id):
            if let status = feature.status, let agent = agents.first(where: { $0.id == id }) {
                AgentDetailView(
                    agent: agent,
                    environment: status.environment,
                    model: model,
                    feature: feature,
                    settings: settings
                ).id(agent.id)
            }
        case .custom:
            CustomAgentDetailView(model: model, settings: settings)
        }
    }

    private var featureRow: some View {
        HStack(spacing: 6) {
            LitheSettingsCheckbox(isOn: Binding(
                get: { model.isAgentConversationEnabled },
                set: { enabled in Task { await model.setAgentConversationEnabled(enabled) } }
            ), title: "Enable Agent conversation")
            LitheInfoTip("Turning this off stops every Agent process.")
        }
    }

    private var statisticsRow: some View {
        HStack(alignment: .top, spacing: 6) {
            LitheSettingsCheckbox(isOn: $settings.agentModelCallStatistics, title: "Model call statistics")
            LitheInfoTip("Routes API-key and Codex subscription requests through a local proxy on this Mac to show model calls, time to first token, output speed and context composition. Requests and credentials are forwarded unchanged and never stored. Applies after reconnecting.")
        }
    }

    private var agentPicker: some View {
        HStack(spacing: 8) {
            Text("Agent").font(LitheTheme.settingsFont)
            LitheSettingsSelect(selection: Binding(
                get: {
                    switch selectedEntry {
                    case .agent(let id): id
                    case .custom: AgentConfiguration.customAgentID
                    }
                },
                set: { model.selectAgentConversationAgent($0) }
            ), options: agents.map(\.id) + [AgentConfiguration.customAgentID], width: 220,
               accessibilityLabel: "Agent", title: { id in
                agents.first { $0.id == id }?.name ?? AgentLocalization.string("Custom Agent", locale: locale)
            }, localizesTitles: false)
            Button { Task { await feature.refresh() } } label: {
                LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "arrow.clockwise", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(feature.phase == .checking || feature.busyAgentID != nil)
            .help("Check Again")
        }
    }

    @ViewBuilder
    private var checkFeedback: some View {
        switch feature.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
            }
            .font(LitheTheme.smallFont)
            .accessibilityIdentifier("agent-check-progress")
        case .ready:
            let incomplete = feature.status?.agents.contains {
                $0.cli?.detected != nil && $0.cli?.installation?.updateAvailable == nil
            } == true
            Text(incomplete ? LocalizedStringKey("Check complete. Some CLI update results are unavailable; see Preflight.") : LocalizedStringKey("Check complete."))
                .font(LitheTheme.smallFont)
                .foregroundStyle(incomplete ? LitheTheme.warning : LitheTheme.secondaryText)
                .accessibilityIdentifier("agent-check-result")
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 3) {
                Text("Check failed.")
                Text(verbatim: reason).textSelection(.enabled)
            }
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.error)
            .accessibilityIdentifier("agent-check-error")
        }
    }

}

// MARK: - Agent detail

private struct AgentDetailView: View {
    @Environment(\.locale) private var locale
    let agent: AgentCatalogStatus
    let environment: AgentRuntimeEnvironment
    @ObservedObject var model: AppModel
    @ObservedObject var feature: AgentManagementFeatureModel
    @ObservedObject var settings: AppSettings
    @State private var expanded: [String: Bool] = [:]

    private var isBusy: Bool { feature.busyAgentID == agent.id }
    private var hasProvider: Bool { settings.agentConfigurations[agent.id]?.isConfigured == true }
    private var checks: [AgentPreflightCheck] {
        let bundle = Bundle.main.url(forResource: settings.language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? .main
        return AgentSetupDiagnostics.preflight(for: agent, environment: environment, hasProvider: hasProvider,
                                               bundle: bundle)
    }

    var body: some View {
        header
        if isBusy {
            AgentInstallProgressView(feature: feature)
        }
        if let error = feature.errors[agent.id] {
            AgentSettingsIssue(error)
        }
        if let result = feature.cliUpdates[agent.id] {
            AgentCliUpdateOutcomeView(result: result)
        }
        versionCard
        preflightCard
        AgentProviderConfigurationView(
            agentID: agent.id,
            name: agent.name,
            source: AppModel.localConfigurationSource(for: agent.id),
            model: model,
            settings: settings
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(LitheTheme.uiFont(size: 14, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
            Text(agent.name).font(LitheTheme.uiFont(size: 14, weight: .semibold))
            AgentBadge(text: "ACP adapter", color: LitheTheme.secondaryText)
                .help("Lithe installs the ACP adapter package, not the vendor CLI. The two are independent and share the CLI's configuration.")
            if !agent.verified {
                AgentBadge(text: "Preview", color: LitheTheme.warning)
                    .help("Lithe has not yet completed a real conversation with this adapter version.")
            }
            if let cli = agent.cli {
                LitheInfoTip(LocalizedStringKey(String(
                    format: AgentLocalization.string("Runs the %@ installed on this Mac through the %@ adapter.", locale: locale),
                    cli.name,
                    agent.package
                )))
            }
            Spacer()
        }
    }

    private var versionCard: some View {
        LitheSettingsSection("Version status") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: AgentLocalization.string("Current version: %@ · Verified target: %@", locale: locale),
                                agent.installedVersion ?? AgentLocalization.string("Not installed", locale: locale), agent.version))
                        .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    if agent.needsUpdate {
                        Text(String(format: AgentLocalization.string("Update to: %@", locale: locale), agent.version))
                            .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    }
                    Text(versionHint)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                if !isBusy {
                    if !agent.isInstalled || (feature.phase == .ready && agent.needsUpdate) {
                        Button(agent.isInstalled ? "Update" : "Install") { feature.install(agent.id) }
                            .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.settingsPrimaryAction, restingOpacity: 1))
                            .controlSize(.small)
                            .disabled(!AgentSetupDiagnostics.canInstallAdapter(checks) || feature.busyAgentID != nil)
                    }
                    if agent.isInstalled {
                        Button("Uninstall") { feature.uninstall(agent.id) }
                            .buttonStyle(LitheSecondaryButtonStyle())
                            .disabled(feature.busyAgentID != nil)
                    }
                }
            }
            Text(agent.package)
                .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
    }

    private var versionHint: String {
        if !agent.isInstalled {
            return AgentSetupDiagnostics.canInstallAdapter(checks)
                ? AgentLocalization.string("Not installed. Install it to start using this Agent.", locale: locale)
                : AgentLocalization.string("Install Node.js and npm before installing the adapter.", locale: locale)
        }
        if agent.updateAvailable == nil {
            return AgentLocalization.string("Could not compare the local adapter with the verified version.", locale: locale)
        }
        return agent.needsUpdate
            ? AgentLocalization.string("A newer verified adapter version is available.", locale: locale)
            : AgentLocalization.string("The local adapter is at or above the verified version.", locale: locale)
    }

    private var preflightCard: some View {
        LitheSettingsSection(title: "Preflight", accessory: {
            if let (text, color) = summaryBadge {
                AgentBadge(text: text, color: color)
            }
        }) {
            VStack(spacing: 4) {
                ForEach(checks) { check in
                    preflightRow(check)
                }
            }
        }
    }

    private var summaryBadge: (LocalizedStringKey, Color)? {
        switch AgentSetupDiagnostics.summary(of: checks) {
        case .pass: ("PASS", LitheTheme.success)
        case .warn: ("WARN", LitheTheme.warning)
        case .fail: ("FAIL", LitheTheme.error)
        case nil: nil
        }
    }

    private func preflightRow(_ check: AgentPreflightCheck) -> some View {
        let isExpanded = expanded[check.id] ?? (check.status != .pass)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    expanded[check.id] = !isExpanded
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .frame(width: 10)
                        Text(check.title)
                            .font(LitheTheme.settingsFont)
                            .lineLimit(1)
                        Spacer()
                        AgentStatusBadge(status: check.status)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .accessibilityIdentifier("agent-preflight-\(agent.id)-\(check.id)")
                if check.id == "cli", let fix = check.fix, !isBusy, feature.phase == .ready {
                    fixButton(fix)
                }
            }
            if isExpanded {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 7) {
                        if !check.details.isEmpty {
                            detailPanel(check.details)
                        }
                        if let text = check.details.isEmpty ? check.message : check.guidance,
                           !text.isEmpty {
                            Text(text)
                                .font(LitheTheme.uiFont(size: 11))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if check.id != "cli", let fix = check.fix, !isBusy, feature.phase == .ready {
                        fixButton(fix)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 6)
    }

    /// Version, path and install source are facts, not a sentence: draw them as
    /// a small inset table so long paths keep their label and can be selected.
    private func detailPanel(_ details: [AgentPreflightCheck.Detail]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: detail.label)
                        .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 76, alignment: .leading)
                    Text(verbatim: detail.value)
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(Text(verbatim: detail.value))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)

                if index < details.count - 1 {
                    Rectangle()
                        .fill(LitheTheme.divider.opacity(0.7))
                        .frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsTextFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(LitheTheme.settingsControlBorder.opacity(0.8), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func fixButton(_ fix: AgentPreflightCheck.Fix) -> some View {
        switch fix {
        case .install:
            Button("Install") { feature.install(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.busyAgentID != nil)
        case .update:
            Button("Update") { feature.install(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.busyAgentID != nil)
        case .installCli:
            Button("Install") { feature.installCli(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.busyAgentID != nil)
                .help(agent.cli?.installation?.updateHint ?? agent.cli?.installHint ?? "")
        case .updateCli:
            Button("Update") { feature.installCli(agent.id) }
                .accessibilityIdentifier("agent-cli-update-\(agent.id)")
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.busyAgentID != nil)
                .help(agent.cli?.installation?.updateHint ?? agent.cli?.installHint ?? "")
        case .fetchLocalConfiguration:
            if let source = AppModel.localConfigurationSource(for: agent.id) {
                Button("Fetch local configuration") {
                    model.importLocalConfiguration(for: agent.id, source: source, name: agent.name)
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }
        }
    }
}

private struct AgentStatusBadge: View {
    @Environment(\.locale) private var locale
    let status: AgentPreflightCheck.Status

    var body: some View {
        let (text, color, symbol): (String, Color, String) = switch status {
        case .pass: ("PASS", LitheTheme.success, "checkmark.circle.fill")
        case .warn: ("WARN", LitheTheme.warning, "exclamationmark.triangle.fill")
        case .fail: ("FAIL", LitheTheme.error, "xmark.octagon.fill")
        }
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(LitheTheme.uiFont(size: 9, weight: .bold))
            Text(text)
                .font(LitheTheme.uiFont(size: 9.5, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }
}

struct AgentBadge: View {
    @Environment(\.locale) private var locale
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(LitheTheme.uiFont(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }
}

// MARK: - Custom agent detail

private struct CustomAgentDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(LitheTheme.uiFont(size: 14, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
            Text("Custom Agent").font(LitheTheme.uiFont(size: 14, weight: .semibold))
            AgentBadge(text: "Custom", color: LitheTheme.secondaryText)
            LitheInfoTip("Run another ACP Agent you installed yourself. It must support signing in with a custom API key gateway.")
            Spacer()
        }
        LitheSettingsSection("Launch") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent executable")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Agent executable", text: $settings.agentCommand)
                    .litheSettingsTextField()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments (one per line)")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                TextEditor(text: $settings.agentArguments)
                    .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    .litheSettingsTextEditor(height: 52)
            }
        }
        AgentProviderConfigurationView(
            agentID: AgentConfiguration.customAgentID,
            name: AgentLocalization.string("Custom Agent", locale: locale),
            source: nil,
            model: model,
            settings: settings
        )
    }
}

// MARK: - Shared pieces

struct AgentSettingsHint: View {
    @Environment(\.locale) private var locale
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AgentCliUpdateOutcomeView: View {
    @Environment(\.locale) private var locale
    let result: AgentCliUpdateResult

    var body: some View {
        LitheBanner(status: result.updaterWarning == nil ? .success : .warning) {
            Text(String(format: AgentLocalization.string("CLI updated to %@", locale: locale), result.cliVersion))
            Text("Reconnect this Agent to refresh its model list.")
            if let warning = result.updaterWarning {
                Text("The installer reported an error, but the new CLI version was verified.")
                DisclosureGroup("Update log") { Text(warning).textSelection(.enabled) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentSettingsIssue: View {
    @Environment(\.locale) private var locale
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        LitheBanner(status: .error) { Text(AgentLocalization.message(text, locale: locale)).textSelection(.enabled) }
    }
}

/// The download's total size is owned by npm and not known in advance.
/// Report actual received bytes and rate instead of inventing an install percentage.
private struct AgentInstallProgressView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: AgentManagementFeatureModel

    var body: some View {
        TimelineView(.periodic(from: feature.operationStartedAt ?? Date(), by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title)
                    Spacer()
                    Button("Cancel") { feature.cancelOperation() }
                        .disabled(feature.isCancelling)
                }
                if let progress = feature.installProgress, progress.downloadedBytes > 0 {
                    Text(String(format: AgentLocalization.string("Downloaded %@ · %@/s", locale: locale),
                                bytes(progress.downloadedBytes), bytes(progress.bytesPerSecond)))
                        .monospacedDigit()
                }
                let elapsed = max(0, Int(timeline.date.timeIntervalSince(feature.operationStartedAt ?? timeline.date)))
                Text(String(format: AgentLocalization.string("Elapsed %lld s", locale: locale), elapsed))
                    .monospacedDigit()
                if let progress = feature.installProgress, progress.stage == .downloading,
                   progress.idleMilliseconds >= 15_000, !feature.isCancelling {
                    Text("Waiting for download data. Check your network or proxy if this continues.")
                        .foregroundStyle(LitheTheme.warning)
                }
            }
            .litheBannerSurface(.info)
        }
    }

    private var title: String {
        if feature.isCancelling { return AgentLocalization.string("Stopping installation…", locale: locale) }
        switch feature.installProgress?.stage {
        case .preparing: return AgentLocalization.string("Preparing download…", locale: locale)
        case .downloading: return AgentLocalization.string("Downloading packages…", locale: locale)
        case .installing: return AgentLocalization.string("Installing packages…", locale: locale)
        case .updating: return AgentLocalization.string("Updating CLI…", locale: locale)
        case nil: return AgentLocalization.string("Working with npm…", locale: locale)
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
