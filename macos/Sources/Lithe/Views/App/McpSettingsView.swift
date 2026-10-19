import SwiftUI

/// Settings › AI › MCP › project grant.
///
/// This section authorizes the open project for connected agents and shows the
/// generated client configuration. The long security explanation lives in the
/// section's ⓘ so the default view stays scannable.
struct McpSettingsView: View {
    @ObservedObject var feature: IdeCapabilitiesFeatureModel
    @ObservedObject var library: McpServerLibraryFeatureModel
    let workspaceURL: URL?

    var body: some View {
        LitheSettingsSection(
            title: "Lithe IDE access",
            accessory: {
                LitheInfoTip("Authorize this project to expose environment, Maven, run configurations and output to connected agents. Output may contain sensitive project data. Access ends when this project or Lithe closes, and the project-level server registration is removed. Enabled plugins can also use this project grant.")
            },
            content: {
                if workspaceURL == nil {
                    openProjectState
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        statusCard
                        accessRow(
                            isOn: $feature.allowConfigure,
                            title: "Allow project environment and Maven configuration changes",
                            info: "Connected agents can change the project JDK, Maven and run configuration settings."
                        )
                        accessRow(
                            isOn: $feature.allowExecute,
                            title: "Allow run, build, reload and stop (executes project code)",
                            info: "Connected agents can run, build, reload and stop the project. Commands execute project code, so enable this only for projects you trust."
                        )
                        if feature.isEnabled {
                            registrationLine
                        }
                        if let error = feature.error {
                            LitheBanner(status: .warning) {
                                Text(error)
                                    .font(LitheTheme.smallFont)
                                    .textSelection(.enabled)
                            }
                        }
                        if !feature.configuration.isEmpty {
                            configurationSection
                        }
                    }
                }
            }
        )
    }

    private var openProjectState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(LitheTheme.uiFont(size: 15))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("No project is open")
                    .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Text("Open a project to let connected agents inspect and control it.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func accessRow(
        isOn: Binding<Bool>,
        title: LocalizedStringKey,
        info: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            LitheSettingsCheckbox(isOn: isOn, title: title)
            LitheInfoTip(info)
            Spacer(minLength: 0)
        }
        .disabled(feature.isEnabled)
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: feature.isEnabled ? "bolt.horizontal.circle.fill" : "bolt.slash.circle")
                .font(LitheTheme.uiFont(size: 18))
                .foregroundStyle(feature.isEnabled ? LitheTheme.success : LitheTheme.secondaryText)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.isEnabled ? "MCP is enabled for this project." : "MCP is off for this project.")
                    .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(feature.isEnabled
                     ? "Connected agents can use the configuration below while this project is open."
                     : "Turn on MCP to generate a configuration for agents.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            Spacer(minLength: 12)

            if feature.isEnabled {
                Button("Disable MCP") { feature.disable() }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 28, fontSize: 12))
            } else {
                Button("Enable MCP") { feature.enable() }
                    .buttonStyle(LithePrimaryButtonStyle(horizontalPadding: 14, height: 28))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    (feature.isEnabled ? LitheTheme.success : LitheTheme.settingsControlBorder).opacity(feature.isEnabled ? 0.35 : 0.8),
                    lineWidth: 1
                )
        }
    }

    /// States whether the Lithe server was written into the project's Agent
    /// configuration, so a conflicting external entry is never silent.
    @ViewBuilder
    private var registrationLine: some View {
        switch library.litheRegistration {
        case .registered:
            HStack(spacing: 5) {
                Circle()
                    .fill(LitheTheme.success)
                    .frame(width: 5, height: 5)
                Text("Registered for this project in \(agentNames).")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.leading, 2)
        case .needsAttention(let message):
            LitheBanner(status: .warning) {
                Text(message)
                    .font(LitheTheme.smallFont)
                    .textSelection(.enabled)
            }
        case .inactive:
            HStack(spacing: 5) {
                Circle()
                    .fill(LitheTheme.tertiaryText)
                    .frame(width: 5, height: 5)
                Text("No project-level MCP entry was written.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.leading, 2)
        }
    }

    private var agentNames: String {
        let names = McpAgent.allCases
            .filter { library.litheRegisteredAgents.contains($0) }
            .map(\.displayName)
        return names.isEmpty ? String(localized: "no Agent") : ListFormatter.localizedString(byJoining: names)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Paste this into your MCP client configuration.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 12)
                Button("Copy agent configuration") { feature.copyConfiguration() }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 28, fontSize: 12))
            }

            Text(feature.configuration)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LitheTheme.settingsTextFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LitheTheme.settingsControlBorder.opacity(0.8), lineWidth: 1)
                }
        }
    }
}
