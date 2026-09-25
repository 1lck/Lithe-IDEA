import SwiftUI
import LitheCoreContracts

/// Settings › Agents: enable the feature, check Node.js, install ACP adapters,
/// and choose each agent's AI provider. Lithe never installs Node.js or the
/// agents' own command-line tools; it only installs the ACP adapter with npm.
struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var feature: AgentManagementFeatureModel
    let onManageProviders: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Agent conversation") {
                LitheSettingsCheckbox(
                    isOn: Binding(
                        get: { model.isAgentConversationEnabled },
                        set: { enabled in Task { await model.setAgentConversationEnabled(enabled) } }
                    ),
                    title: "Enable Agent conversation"
                )
                hint("An Agent starts when you open the Agent panel in a project. Disabling this feature stops every Agent process.")
            }
            section("Environment") { environment }
            if let status = feature.status {
                ForEach(status.agents) { agent in
                    section(agent.name) { agentCard(agent) }
                }
            }
            section("Custom Agent") { customAgent }
        }
        .task { await feature.refresh() }
    }

    // MARK: Environment

    @ViewBuilder
    private var environment: some View {
        switch feature.phase {
        case .idle, .checking where feature.status == nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Node.js and npm…").foregroundStyle(LitheTheme.secondaryText)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
        default:
            if let environment = feature.status?.environment {
                toolRow("Node.js", environment.node)
                toolRow("npm", environment.npm)
                if !environment.usedLoginShell {
                    hint("Your login shell did not report a PATH, so only Lithe's own PATH was searched.")
                }
            }
        }
        HStack(spacing: 8) {
            Button("Check Again") { Task { await feature.refresh() } }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(feature.phase == .checking)
            if feature.phase == .checking, feature.status != nil {
                ProgressView().controlSize(.small)
            }
        }
        hint("Agents run on the Node.js installed on this Mac. Install or update Node.js yourself, then check again.")
    }

    private func toolRow(_ name: String, _ tool: AgentRuntimeTool?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tool == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tool == nil ? LitheTheme.warning : LitheTheme.success)
            Text(name).font(.system(size: 12, weight: .medium))
            if let tool {
                Text("\(tool.version) · \(tool.path)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Not found").foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    // MARK: Catalog agents

    @ViewBuilder
    private func agentCard(_ agent: AgentCatalogStatus) -> some View {
        HStack(spacing: 8) {
            Text(agent.description).foregroundStyle(LitheTheme.secondaryText)
            if !agent.verified {
                Text("Not verified yet")
                    .font(LitheTheme.smallFont)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LitheTheme.hoverBackground, in: Capsule())
                    .help("Lithe has not yet completed a real conversation with this adapter version.")
            }
        }
        Text(installState(agent))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(LitheTheme.secondaryText)
        if let cli = agent.cli {
            toolRow(cli.name, cli.detected)
            hint("\(agent.name) runs the \(cli.name) installed on this Mac (\(cli.minimumVersion) or later), so Lithe does not download another copy.")
        }
        ForEach(agent.issues, id: \.self) { issue in
            Label(issue, systemImage: "exclamationmark.triangle")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.warning)
        }
        if let error = feature.errors[agent.id] {
            Text(error)
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.warning)
                .textSelection(.enabled)
                .lineLimit(8)
        }
        installButtons(agent)
        providerPicker(
            agentID: agent.id,
            name: agent.name,
            apiProtocol: CommitMessageAPIProtocol(rawValue: agent.protocol) ?? .responses
        )
    }

    private func installState(_ agent: AgentCatalogStatus) -> String {
        switch agent.installedVersion {
        case nil: "Not installed · \(agent.package)@\(agent.version)"
        case let installed? where installed != agent.version: "Installed \(installed) · update to \(agent.version) available"
        case let installed?: "Installed \(installed)"
        }
    }

    @ViewBuilder
    private func installButtons(_ agent: AgentCatalogStatus) -> some View {
        let isBusy = feature.busyAgentID == agent.id
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().controlSize(.small)
                Text(agent.isInstalled ? "Working…" : "Installing with npm…")
                    .foregroundStyle(LitheTheme.secondaryText)
                Button("Cancel") { feature.cancelOperation() }
                    .buttonStyle(LitheSecondaryButtonStyle())
            } else {
                if !agent.isInstalled || agent.needsUpdate {
                    Button(agent.isInstalled ? "Update" : "Install") { feature.install(agent.id) }
                        .buttonStyle(LithePrimaryButtonStyle(
                            backgroundColor: LitheTheme.settingsPrimaryAction,
                            restingOpacity: 1
                        ))
                        .disabled(!agent.issues.isEmpty || feature.busyAgentID != nil)
                }
                if agent.isInstalled {
                    Button("Uninstall") { feature.uninstall(agent.id) }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        .disabled(feature.busyAgentID != nil)
                }
            }
        }
        if isBusy || !agent.isInstalled {
            hint(agent.cli == nil
                 ? "The adapter is installed with your npm into Lithe's application data. The first install can download a large runtime and take a few minutes."
                 : "The adapter is installed with your npm into Lithe's application data.")
        }
    }

    // MARK: Custom agent

    @ViewBuilder
    private var customAgent: some View {
        hint("Run another ACP Agent you installed yourself. It must support signing in with a custom API key gateway.")
        TextField("Agent executable", text: $settings.agentCommand)
            .litheSettingsTextField()
        Text("Arguments (one per line)").font(LitheTheme.smallFont)
        TextEditor(text: $settings.agentArguments)
            .frame(height: 48)
        providerPicker(
            agentID: AgentConfiguration.customAgentID,
            name: "Custom Agent",
            apiProtocol: .responses
        )
    }

    // MARK: Shared

    @ViewBuilder
    private func providerPicker(agentID: String, name: String, apiProtocol: CommitMessageAPIProtocol) -> some View {
        let candidates = settings.agentProviderCandidates(for: apiProtocol)
        if candidates.isEmpty {
            HStack(spacing: 8) {
                Text("Add an AI provider that uses \(apiProtocol.title) to use \(name).")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                Button("Manage AI Providers…", action: onManageProviders)
                    .buttonStyle(LitheSecondaryButtonStyle())
            }
        } else {
            Picker("AI provider", selection: Binding(
                get: { settings.agentConfigurations[agentID]?.providerID },
                set: { settings.setAgentProvider($0, for: agentID, name: name) }
            )) {
                Text("Not used").tag(UUID?.none)
                ForEach(candidates) { provider in
                    Text(provider.name).tag(UUID?.some(provider.id))
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            .lithePointer()
            hint("Only API keys are used. The Agent's own account sign-in, such as a ChatGPT login, is never used.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
