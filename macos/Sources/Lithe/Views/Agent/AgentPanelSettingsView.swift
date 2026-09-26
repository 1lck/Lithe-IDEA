import AppKit
import SwiftUI
import LitheCoreContracts

/// Settings shown inside the Agent panel: an agent list on the left and one
/// agent's detail on the right, in the style of Codeg's "Agent SDK
/// Management". Each agent follows the user's own CLI configuration for its
/// endpoint, model and API key. Lithe never installs Node.js or the agents'
/// own command-line tools; it only installs ACP adapters with npm.
struct AgentPanelSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var feature: AgentManagementFeatureModel
    let onDone: () -> Void
    @State private var section: AgentSettingsSection = .agents

    /// Pages of the panel settings. Only Agents exists today; the rail keeps
    /// room for more without changing the layout.
    enum AgentSettingsSection: CaseIterable, Hashable {
        case agents

        var title: LocalizedStringKey {
            switch self {
            case .agents: "Agents"
            }
        }

        var subtitle: LocalizedStringKey {
            switch self {
            case .agents: "Install ACP adapters, check the runtime, and follow your local CLI configuration."
            }
        }

        var systemImage: String {
            switch self {
            case .agents: "sparkles"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onDone) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .litheIconButton()
                .help("Back to the conversation")
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(LitheTheme.toolHeaderInactive)
            Divider().overlay(LitheTheme.divider)
            HStack(spacing: 0) {
                rail
                Divider().overlay(LitheTheme.divider)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title).font(.system(size: 16, weight: .semibold))
                            Text(section.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        switch section {
                        case .agents:
                            AgentsManagementPage(model: model, settings: settings, feature: feature)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { await feature.refresh() }
    }

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(AgentSettingsSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(section == item ? Color.white : LitheTheme.secondaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(section == item ? LitheTheme.accent : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help(item.title)
            }
            Spacer()
        }
        .padding(6)
        .frame(width: 44)
        .background(LitheTheme.sidebar)
    }
}

// MARK: - Agents page

/// Agent list on the left with a status badge per agent, selected agent's
/// detail on the right: header with enable switch, preflight checklist,
/// provider picker. The feature toggle and custom agent are list entries too.
private struct AgentsManagementPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var feature: AgentManagementFeatureModel
    @State private var selectedID: String?

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
        featureRow
        segments
        switch selectedEntry {
        case .agent(let id):
            if let status = feature.status, let agent = agents.first(where: { $0.id == id }) {
                AgentDetailView(
                    agent: agent,
                    environment: status.environment,
                    model: model,
                    feature: feature,
                    settings: settings
                )
            }
        case .custom:
            CustomAgentDetailView(model: model, settings: settings)
        }
    }

    private var featureRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Agent conversation")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Turning this off stops every Agent process.")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.isAgentConversationEnabled },
                set: { enabled in Task { await model.setAgentConversationEnabled(enabled) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(12)
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }

    /// One segment per agent, with the preflight summary as a coloured dot.
    private var segments: some View {
        HStack(spacing: 2) {
            if feature.status == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.system(size: 11.5)).foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            ForEach(agents) { agent in
                segment(
                    title: agent.name,
                    systemImage: "cpu",
                    dot: summaryColor(for: agent),
                    isSelected: selectedEntry == .agent(agent.id),
                    isBusy: feature.busyAgentID == agent.id
                ) { selectedID = agent.id }
            }
            segment(
                title: String(localized: "Custom Agent"),
                systemImage: "terminal",
                dot: settings.agentConfigurations[AgentConfiguration.customAgentID]?.providerID != nil ? LitheTheme.success : nil,
                isSelected: selectedEntry == .custom,
                isBusy: false
            ) { selectedID = AgentConfiguration.customAgentID }
            Button {
                Task { await feature.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .foregroundStyle(LitheTheme.secondaryText)
            .disabled(feature.phase == .checking)
            .help("Check Again")
        }
        .padding(3)
        .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }

    private func segment(
        title: String, systemImage: String, dot: Color?, isSelected: Bool, isBusy: Bool, select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: isSelected ? .medium : .regular)).lineLimit(1)
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isSelected ? Color.white : LitheTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? LitheTheme.accent : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func summaryColor(for agent: AgentCatalogStatus) -> Color? {
        guard let environment = feature.status?.environment else { return nil }
        let checks = AgentSetupDiagnostics.preflight(
            for: agent,
            environment: environment,
            hasProvider: settings.agentConfigurations[agent.id]?.providerID != nil
        )
        switch AgentSetupDiagnostics.summary(of: checks) {
        case .pass: return LitheTheme.success
        case .warn: return LitheTheme.warning
        case .fail: return LitheTheme.error
        case nil: return nil
        }
    }
}

// MARK: - Agent detail

private struct AgentDetailView: View {
    let agent: AgentCatalogStatus
    let environment: AgentRuntimeEnvironment
    @ObservedObject var model: AppModel
    @ObservedObject var feature: AgentManagementFeatureModel
    @ObservedObject var settings: AppSettings
    @State private var expanded: Set<String> = []

    private var isBusy: Bool { feature.busyAgentID == agent.id }
    private var hasProvider: Bool { settings.agentConfigurations[agent.id]?.providerID != nil }
    private var checks: [AgentPreflightCheck] {
        AgentSetupDiagnostics.preflight(for: agent, environment: environment, hasProvider: hasProvider)
    }

    var body: some View {
        header
        if isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working with npm…")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button("Cancel") { feature.cancelOperation() }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
            }
            .padding(10)
            .background(LitheTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if let error = feature.errors[agent.id] {
            AgentSettingsIssue(error)
        }
        versionCard
        preflightCard
        AgentLocalConfigurationCard(
            agentID: agent.id,
            name: agent.name,
            source: AppModel.localConfigurationSource(for: agent.id),
            model: model,
            settings: settings
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                Text(agent.name).font(.system(size: 14, weight: .semibold))
                AgentBadge(text: "ACP adapter", color: LitheTheme.secondaryText)
                    .help("Lithe installs the ACP adapter package, not the vendor CLI. The two are independent and share the CLI's configuration.")
                if !agent.verified {
                    AgentBadge(text: "Preview", color: LitheTheme.warning)
                        .help("Lithe has not yet completed a real conversation with this adapter version.")
                }
                Spacer()
            }
            if let cli = agent.cli {
                Text(String(format: String(localized: "Runs the %@ installed on this Mac through the %@ adapter."), cli.name, agent.package))
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versionCard: some View {
        AgentSettingsCard(title: "Version status", systemImage: "shippingbox") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: String(localized: "Pinned: %@ · Local: %@"),
                                agent.version, agent.installedVersion ?? String(localized: "Not installed")))
                        .font(.system(size: 12, design: .monospaced))
                    Text(versionHint)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                if !isBusy {
                    if !agent.isInstalled || agent.needsUpdate {
                        Button(agent.isInstalled ? "Update" : "Install") { feature.install(agent.id) }
                            .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.accent, restingOpacity: 1))
                            .controlSize(.small)
                            .disabled(!AgentSetupDiagnostics.canInstallAdapter(checks) || feature.busyAgentID != nil)
                    }
                    if agent.isInstalled {
                        Button("Uninstall") { feature.uninstall(agent.id) }
                            .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
                            .disabled(feature.busyAgentID != nil)
                    }
                }
            }
            Text(agent.package)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
    }

    private var versionHint: String {
        if !agent.isInstalled {
            return AgentSetupDiagnostics.canInstallAdapter(checks)
                ? String(localized: "Not installed. Install it to start using this Agent.")
                : String(localized: "Install Node.js and npm before installing the adapter.")
        }
        return agent.needsUpdate
            ? String(localized: "An update is available.")
            : String(localized: "Up to date.")
    }

    private var preflightCard: some View {
        AgentSettingsCard(
            title: "Preflight",
            systemImage: "checklist",
            badge: summaryBadge
        ) {
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
        let isExpanded = expanded.contains(check.id) || check.status != .pass
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded.contains(check.id) { expanded.remove(check.id) } else { expanded.insert(check.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 10)
                    Text(check.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    AgentStatusBadge(status: check.status)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            if isExpanded {
                HStack(alignment: .top, spacing: 8) {
                    Text(check.message)
                        .font(.system(size: 11, design: check.status == .pass ? .monospaced : .default))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let fix = check.fix, !isBusy {
                        fixButton(fix)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(LitheTheme.inputBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func fixButton(_ fix: AgentPreflightCheck.Fix) -> some View {
        switch fix {
        case .install:
            Button("Install") { feature.install(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 22, fontSize: 11))
                .disabled(feature.busyAgentID != nil)
        case .update:
            Button("Update") { feature.install(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 22, fontSize: 11))
                .disabled(feature.busyAgentID != nil)
        case .installCli:
            Button("Install") { feature.installCli(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 22, fontSize: 11))
                .disabled(feature.busyAgentID != nil)
                .help(agent.cli?.installHint ?? "")
        case .updateCli:
            Button("Update") { feature.installCli(agent.id) }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 22, fontSize: 11))
                .disabled(feature.busyAgentID != nil)
                .help(agent.cli?.installHint ?? "")
        case .fetchLocalConfiguration:
            if let source = AppModel.localConfigurationSource(for: agent.id) {
                Button("Fetch local configuration") {
                    model.importLocalConfiguration(for: agent.id, source: source, name: agent.name)
                }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 8, height: 22, fontSize: 11))
            }
        }
    }
}

private struct AgentStatusBadge: View {
    let status: AgentPreflightCheck.Status

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .pass: ("PASS", LitheTheme.success)
        case .warn: ("WARN", LitheTheme.warning)
        case .fail: ("FAIL", LitheTheme.error)
        }
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
    }
}

struct AgentBadge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Custom agent detail

private struct CustomAgentDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
            Text("Custom Agent").font(.system(size: 14, weight: .semibold))
            AgentBadge(text: "Custom", color: LitheTheme.secondaryText)
            Spacer()
        }
        AgentSettingsHint("Run another ACP Agent you installed yourself. It must support signing in with a custom API key gateway.")
        AgentSettingsCard(title: "Launch", systemImage: "play") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent executable")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Agent executable", text: $settings.agentCommand)
                    .litheSettingsTextField()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments (one per line)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                TextEditor(text: $settings.agentArguments)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 52)
                    .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius).stroke(LitheTheme.inputBorder, lineWidth: 1))
            }
        }
        AgentLocalConfigurationCard(
            agentID: AgentConfiguration.customAgentID,
            name: String(localized: "Custom Agent"),
            source: nil,
            model: model,
            settings: settings
        )
    }
}

// MARK: - Shared pieces

/// Shows which local CLI configuration the agent follows and fetches it on
/// demand. Users edit the endpoint, model and key in their own CLI files;
/// Lithe only reads them.
private struct AgentLocalConfigurationCard: View {
    let agentID: String
    let name: String
    /// The configuration this agent naturally follows; `nil` lets the user
    /// pick either one for a custom agent.
    let source: AIConfigurationSourceKind?
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    private var provider: AIProviderProfile? { settings.agentProvider(for: agentID) }

    var body: some View {
        AgentSettingsCard(title: "Local configuration", systemImage: "doc.text.magnifyingglass") {
            if let provider {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(LitheTheme.success)
                        Text(provider.name).font(.system(size: 12, weight: .medium))
                    }
                    Text(provider.endpoint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(provider.endpoint)
                    if !provider.model.isEmpty {
                        Text(provider.model)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
            } else {
                Text("Not fetched yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            HStack(spacing: 8) {
                if let source {
                    Button(provider == nil ? "Fetch local configuration" : "Fetch again") {
                        model.importLocalConfiguration(for: agentID, source: source, name: name)
                    }
                    .buttonStyle(LithePrimaryButtonStyle(backgroundColor: LitheTheme.accent, restingOpacity: 1))
                    .controlSize(.small)
                } else {
                    ForEach(AIConfigurationSourceKind.allCases) { kind in
                        Button(String(format: String(localized: "Use %@ configuration"), kind.title)) {
                            model.importLocalConfiguration(for: agentID, source: kind, name: name)
                        }
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
                    }
                }
                if provider != nil {
                    Button("Unlink") {
                        settings.setAgentProvider(nil, for: agentID, name: name)
                    }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
                }
                Spacer()
            }
            AgentSettingsHint(hint)
        }
    }

    private var hint: LocalizedStringKey {
        switch source {
        case .codex: "Reads the API URL, model and key from ~/.codex/config.toml and auth.json. Edit those files to change them, then fetch again."
        case .claude: "Reads the API URL, model and key from ~/.claude/settings.json and ~/.claude.json. Edit those files to change them, then fetch again."
        case nil: "A custom Agent can follow either your Codex or your Claude configuration."
        }
    }
}

struct AgentSettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var badge: (LocalizedStringKey, Color)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let (text, color) = badge {
                    AgentBadge(text: text, color: color)
                }
                Spacer()
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }
}

struct AgentSettingsHint: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentSettingsIssue: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(LitheTheme.smallFont)
        .foregroundStyle(LitheTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
    }
}
