import SwiftUI
import LitheModuleAPI

struct LSPControlCenterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LSPControlCenterContent(
            usageModel: model.languageToolingFeature.projectUsage,
            input: model.languageToolingFeature.projectUsageInput(
                workspaceURL: model.workspaceURL, snapshot: model.workspaceFeature.appliedSnapshot
            )
        )
    }
}

struct LSPControlCenterContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var usageModel: LSPProjectUsageModel
    let input: LSPProjectUsageInput
    private let localizationBundle: Bundle
    private var request: LSPProjectUsageRequest { input.request }

    init(usageModel: LSPProjectUsageModel, input: LSPProjectUsageInput, localizationBundle: Bundle = .main) {
        self.usageModel = usageModel
        self.input = input
        self.localizationBundle = localizationBundle
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSummary
                    if let usage = usageModel.summary(for: request) {
                        // Building a plugin snapshot also discovers settings and
                        // runtime resources. Share it across this render's rows
                        // and notices without caching live plugin state.
                        let snapshots = model.pluginSnapshots
                        // Conflicting packages can remain visible for inspection.
                        // Preserve the previous first-match lookup precedence.
                        let snapshotsByID = Dictionary(snapshots.map { ($0.id, $0) },
                                                       uniquingKeysWith: { first, _ in first })
                        let notices = pluginNotices(in: usage, snapshots: snapshotsByID)
                        let servers = projectLanguageServers(in: usage, snapshots: snapshotsByID)
                        let hasChangesPendingRestart = snapshots.contains(where: \.hasChangesPendingRestart)
                        ForEach(notices, id: \.self) { notice in
                            phpPluginNotice(notice, hasChangesPendingRestart: hasChangesPendingRestart)
                        }
                        if servers.isEmpty && notices.isEmpty {
                            emptyState
                        } else {
                            ForEach(servers) { descriptor in
                                languageRow(descriptor)
                            }
                        }
                    } else {
                        ProgressView().accessibilityLabel(Text(settings.language.localizedString("native.loading", bundle: localizationBundle)))
                    }
                    if model.languageProviderCatalogSnapshot.isDegraded {
                        degradedCatalogNotice
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
            .background(LitheTheme.settingsSurface)
        }
        .background(LitheTheme.settingsSurface)
        .background {
            if LitheSignpost.settingsLatencyTracingEnabled,
               usageModel.summary(for: request) != nil {
                SettingsPageLatencyProbe(category: SettingsCategory.lsp.id)
                    .accessibilityHidden(true)
            }
        }
        .task(id: request) {
            await usageModel.load(input.request, files: input.files)
        }
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.projectName)
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(settings.language.localizedString("native.inline.onlyLanguagesUsedByThisProjectAreShownChangesAreSavedAutomaticallyForThisPr"))
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languageRow(_ descriptor: LanguageProviderDescriptor) -> some View {
        let status = serverStatus(for: descriptor)
        let isEnabled = !model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id)
        let mavenResults: [MavenProfileProjectResult]? = model.languageToolingSessionsIfActive.map {
            Array($0.mavenProfileProjectResults.values)
        }
        let mavenState = descriptor.id == "java"
            ? LSPControlCenterPresenter.mavenProfileState(mavenResults ?? [])
            : .idle

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.displayName)
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(statusDescription(for: descriptor, status: status))
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(status == .error ? LitheTheme.error : LitheTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                LitheSettingsCheckbox(
                    isOn: Binding(
                        get: { isEnabled },
                        set: { model.setLanguageServerEnabled($0, providerID: descriptor.id) }
                    ),
                    accessibilityLabel: LocalizedStringKey(settings.language.localizedFormat("native.inline.enableArg1LanguageServer", String(describing: descriptor.displayName)))
                )
            }
            if descriptor.id == "java", case .partiallyFailed = mavenState,
               let sessions = model.languageToolingSessionsIfActive
            {
                Button(settings.language.localizedString("native.inline.retryMavenConfiguration")) {
                    sessions.retryMavenProfiles(providerID: descriptor.id)
                }
                .buttonStyle(LitheActionButtonStyle())
            }

        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(LitheTheme.settingsSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .stroke(LitheTheme.divider, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.language.localizedString("native.inline.noConfigurableLanguageServers"))
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(settings.language.localizedString("native.inline.settingsAppearHereWhenSupportedSourceLanguagesAreDetected"))
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.vertical, 10)
    }

    private var degradedCatalogNotice: some View {
        LitheBanner(status: .warning) {
            Text(settings.language.localizedString("native.inline.languageServerConfigurationIsDegradedCompatibilitySettingsAreInUse"))
        }
    }

    private func projectLanguageServers(
        in usage: LSPProjectUsageSummary,
        snapshots: [PluginID: PluginManagementSnapshot]
    ) -> [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .filter { usage.providerIDs.contains($0.id) }
            .filter { descriptor in
                guard let entry = officialPluginEntry(languageID: descriptor.id) else { return true }
                return pluginIsReady(entry, snapshots: snapshots)
            }
    }

    // Languages owned by a published official plugin are controlled here only once
    // that plugin is installed, enabled, and loaded in this process.
    private func officialPluginEntry(languageID: String) -> OfficialPluginCatalog.Entry? {
        OfficialPluginCatalog.publishedEntries.first { $0.languageID == languageID }
    }

    private func pluginIsReady(
        _ entry: OfficialPluginCatalog.Entry,
        snapshots: [PluginID: PluginManagementSnapshot]
    ) -> Bool {
        guard let snapshot = snapshots[entry.id] else { return false }
        return snapshot.isEnabled && !snapshot.requiresRestart && !snapshot.isQuarantined
    }

    private func pluginNotices(
        in usage: LSPProjectUsageSummary,
        snapshots: [PluginID: PluginManagementSnapshot]
    ) -> [String] {
        OfficialPluginCatalog.entries.compactMap { entry in
            guard usage.pluginIDs.contains(entry.id.rawValue) else { return nil }
            if let replacementID = entry.communityReplacementID {
                return migratedPluginNotice(entry, replacementID: replacementID, snapshots: snapshots)
            }
            guard !pluginIsReady(entry, snapshots: snapshots) else { return nil }
            return pluginNotice(entry, snapshots: snapshots)
        }
    }

    /// Go and PHP moved to Lithe Store: point at the community plugin, and at
    /// the uninstall-and-restart step while the retired official one remains.
    private func migratedPluginNotice(
        _ entry: OfficialPluginCatalog.Entry,
        replacementID: PluginID,
        snapshots: [PluginID: PluginManagementSnapshot]
    ) -> String? {
        let name = entry.displayName
        let language = entry.languageDisplayName
        if let retired = snapshots[entry.id] {
            if retired.installationStatus == .uninstallPending {
                return settings.language.localizedFormat("native.inline.restartLitheToFinishUninstallingTheOldArg1ThenInstallTheCommunityArg2FromLi", String(describing: name), String(describing: name))
            }
            return settings.language.localizedFormat("native.inline.arg1MovedToLitheStoreAsACommunityPluginAndTheOldOfficialVersionGetsNoUpdate", String(describing: name))
        }
        guard let community = snapshots[replacementID] else {
            return settings.language.localizedFormat("native.inline.thisArg1ProjectNeedsArg2InstallItFromLitheStoreInThePluginManagementMarketp", String(describing: language), String(describing: name))
        }
        if community.requiresRestart {
            return settings.language.localizedFormat("native.inline.arg1IsInstalledRestartLitheBeforeControllingItsLanguageServerHere", String(describing: name))
        }
        guard !community.isEnabled else { return nil }
        return settings.language.localizedFormat("native.inline.arg1IsDisabledEnableItFromPluginManagementFirst", String(describing: name))
    }

    private func pluginNotice(
        _ entry: OfficialPluginCatalog.Entry,
        snapshots: [PluginID: PluginManagementSnapshot]
    ) -> String {
        let name = entry.displayName
        let language = entry.languageDisplayName
        guard let snapshot = snapshots[entry.id] else {
            return settings.language.localizedFormat("native.inline.thisArg1ProjectNeedsArg2DownloadAndInstallItFromPluginManagement", String(describing: language), String(describing: name))
        }
        if snapshot.installationStatus == .removed {
            return settings.language.localizedFormat("native.inline.thisArg1ProjectNeedsArg2WhichWasRemovedRestoreItFromPluginManagementThenRes", String(describing: language), String(describing: name))
        }
        if snapshot.requiresRestart {
            return settings.language.localizedFormat("native.inline.arg1IsInstalledRestartLitheBeforeControllingItsLanguageServerHere", String(describing: name))
        }
        if snapshot.isQuarantined {
            return settings.language.localizedFormat("native.inline.arg1WasQuarantinedAfterItsPreviousSessionReEnableItFromPluginManagement", String(describing: name))
        }
        return settings.language.localizedFormat("native.inline.arg1IsDisabledEnableItFromPluginManagementFirst", String(describing: name))
    }

    private func phpPluginNotice(_ message: String, hasChangesPendingRestart: Bool) -> some View {
        LitheBanner(status: .info) {
            Text(message).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(settings.language.localizedString("native.inline.openPluginManagement")) {
                    model.showSettings(category: .plugins)
                }
                if hasChangesPendingRestart {
                    RestartLitheButton(prominent: false)
                }
            }
        }
    }

    private func serverStatus(for descriptor: LanguageProviderDescriptor) -> LSPServerStatus {
        LSPControlCenterPresenter.serverStatus(
            isDisabled: model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id),
            sessionState: model.languageToolingSessionsIfActive?.languageServerStates[descriptor.id]
        )
    }

    private func statusDescription(
        for descriptor: LanguageProviderDescriptor,
        status: LSPServerStatus
    ) -> String {
        if descriptor.id == "java", let manager = model.languageToolingSessionsIfActive {
            let mavenState = LSPControlCenterPresenter.mavenProfileState(
                Array(manager.mavenProfileProjectResults.values)
            )
            switch mavenState {
            case .applying:
                return settings.language.localizedString("native.inline.languageServiceConnectedApplyingMavenConfiguration")
            case .partiallyFailed(let failed, let total):
                return settings.language.localizedFormat("native.inline.someModulesFailedArg1Arg2LanguageServiceRemainsAvailable", String(describing: failed), String(describing: total))
            case .idle, .complete:
                break
            }
        }
        switch status {
        case .starting: return settings.language.localizedString("native.inline.starting")
        case .initializing: return settings.language.localizedString("native.inline.initializingProjectIndex")
        case .active: return settings.language.localizedString("native.inline.running")
        case .stopping: return settings.language.localizedString("native.inline.stopping")
        case .disabled: return settings.language.localizedString("native.inline.off")
        case .stopped:
            return settings.language.localizedString("native.inline.startsOnDemandWhenAMatchingFileIsOpened")
        case .error:
            if descriptor.id == "java" {
                return settings.language.localizedString("native.inline.failedToStartCheckTheLspRuntimeJdk")
            }
            return settings.language.localizedString("native.inline.failedToStartCheckTheLanguageServerConfiguration")
        }
    }

    private func statusColor(_ status: LSPServerStatus) -> Color {
        switch status {
        case .starting, .initializing: LitheTheme.accent
        case .active: LitheTheme.success
        case .stopping: LitheTheme.warning
        case .stopped, .disabled: LitheTheme.secondaryText
        case .error: LitheTheme.error
        }
    }
}
