import SwiftUI
import LitheModuleAPI

struct LSPControlCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    private var usesChinese: Bool { settings.language == .simplifiedChinese }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSummary
                    ForEach(pluginNotices, id: \.self) { notice in
                        phpPluginNotice(notice)
                    }
                    if projectLanguageServers.isEmpty && pluginNotices.isEmpty {
                        emptyState
                    } else {
                        ForEach(projectLanguageServers) { descriptor in
                            languageRow(descriptor)
                        }
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
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.projectName)
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(usesChinese
                ? "仅显示当前项目使用的语言。开关状态会自动为此项目保存，关闭后会停止语言服务器并释放资源，下次打开仍保持关闭。"
                : "Only languages used by this project are shown. Changes are saved automatically for this project. Turning a language off stops its server, releases its resources, and keeps it off when you reopen the project.")
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
                    accessibilityLabel: LocalizedStringKey(usesChinese
                        ? "启用 \(descriptor.displayName) 语言服务器"
                        : "Enable \(descriptor.displayName) language server")
                )
            }
            if descriptor.id == "java", case .partiallyFailed = mavenState,
               let sessions = model.languageToolingSessionsIfActive
            {
                Button(usesChinese ? "重试 Maven 配置" : "Retry Maven configuration") {
                    sessions.retryMavenProfiles(providerID: descriptor.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            Text(usesChinese ? "当前项目没有可配置的语言服务器" : "No configurable language servers")
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(usesChinese
                ? "识别到支持的源码语言后，会在这里显示对应设置。"
                : "Settings appear here when supported source languages are detected.")
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.vertical, 10)
    }

    private var degradedCatalogNotice: some View {
        LitheBanner(status: .warning) {
            Text(usesChinese ? "语言服务器配置加载异常，当前正在使用兼容配置。" : "Language server configuration is degraded; compatibility settings are in use.")
        }
    }

    private var projectLanguageServers: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .filter { descriptor in
                guard let entry = officialPluginEntry(languageID: descriptor.id) else { return true }
                return pluginIsReady(entry)
            }
            .filter { descriptor in
                model.projectFiles.contains { descriptor.handles(fileURL: $0) }
            }
    }

    // Languages owned by a published official plugin are controlled here only once
    // that plugin is installed, enabled, and loaded in this process.
    private func officialPluginEntry(languageID: String) -> OfficialPluginCatalog.Entry? {
        OfficialPluginCatalog.publishedEntries.first { $0.languageID == languageID }
    }

    private func pluginSnapshot(_ entry: OfficialPluginCatalog.Entry) -> PluginManagementSnapshot? {
        model.pluginSnapshots.first { $0.id == entry.id }
    }

    private func pluginIsReady(_ entry: OfficialPluginCatalog.Entry) -> Bool {
        guard let snapshot = pluginSnapshot(entry) else { return false }
        return snapshot.isEnabled && !snapshot.requiresRestart && !snapshot.isQuarantined
    }

    private func projectUses(_ entry: OfficialPluginCatalog.Entry) -> Bool {
        model.projectFiles.contains { fileURL in
            entry.fileExtensions.contains(fileURL.pathExtension.lowercased())
                || entry.projectFileNames.contains(fileURL.lastPathComponent.lowercased())
        }
    }

    private var pluginNotices: [String] {
        OfficialPluginCatalog.entries.compactMap { entry in
            guard projectUses(entry) else { return nil }
            if let replacementID = entry.communityReplacementID {
                return migratedPluginNotice(entry, replacementID: replacementID)
            }
            guard !pluginIsReady(entry) else { return nil }
            return pluginNotice(entry)
        }
    }

    /// Go and PHP moved to Lithe Store: point at the community plugin, and at
    /// the uninstall-and-restart step while the retired official one remains.
    private func migratedPluginNotice(_ entry: OfficialPluginCatalog.Entry, replacementID: PluginID) -> String? {
        let name = entry.displayName
        let language = entry.languageDisplayName
        if let retired = pluginSnapshot(entry) {
            if retired.installationStatus == .uninstallPending {
                return usesChinese
                    ? "重启 Lithe 以完成旧版 \(name) 的卸载，然后在插件市场的 Lithe Store 中安装社区版 \(name)。"
                    : "Restart Lithe to finish uninstalling the old \(name), then install the community \(name) from Lithe Store in the Marketplace."
            }
            return usesChinese
                ? "\(name) 已迁移为 Lithe Store 社区插件，旧官方版不再更新。请在插件管理中卸载旧版并重启 Lithe，再安装社区版。"
                : "\(name) moved to Lithe Store as a community plugin, and the old official version gets no updates. Uninstall it from Plugin Management, restart Lithe, then install the community version."
        }
        guard let community = model.pluginSnapshots.first(where: { $0.id == replacementID }) else {
            return usesChinese
                ? "检测到 \(language) 项目，请在插件管理的插件市场中，从 Lithe Store 安装 \(name)。"
                : "This \(language) project needs \(name). Install it from Lithe Store in the Plugin Management Marketplace."
        }
        if community.requiresRestart {
            return usesChinese
                ? "\(name) 已安装，重启 Lithe 后才能在这里控制语言服务器。"
                : "\(name) is installed. Restart Lithe before controlling its language server here."
        }
        guard !community.isEnabled else { return nil }
        return usesChinese
            ? "\(name) 插件已禁用，请先在插件管理中启用。"
            : "\(name) is disabled. Enable it from Plugin Management first."
    }

    private func pluginNotice(_ entry: OfficialPluginCatalog.Entry) -> String {
        let name = entry.displayName
        let language = entry.languageDisplayName
        guard let snapshot = pluginSnapshot(entry) else {
            return usesChinese
                ? "检测到 \(language) 项目，请先在插件管理中下载并安装 \(name)。"
                : "This \(language) project needs \(name). Download and install it from Plugin Management."
        }
        if snapshot.installationStatus == .removed {
            return usesChinese
                ? "检测到 \(language) 项目，但 \(name) 已被移除。请在插件管理中恢复它，然后重启 Lithe。"
                : "This \(language) project needs \(name), which was removed. Restore it from Plugin Management, then restart Lithe."
        }
        if snapshot.requiresRestart {
            return usesChinese
                ? "\(name) 已安装，重启 Lithe 后才能在这里控制语言服务器。"
                : "\(name) is installed. Restart Lithe before controlling its language server here."
        }
        if snapshot.isQuarantined {
            return usesChinese
                ? "\(name) 因上次启动异常被隔离，请先在插件管理中重新启用。"
                : "\(name) was quarantined after its previous session. Re-enable it from Plugin Management."
        }
        return usesChinese
            ? "\(name) 插件已禁用，请先在插件管理中启用。"
            : "\(name) is disabled. Enable it from Plugin Management first."
    }

    private func phpPluginNotice(_ message: String) -> some View {
        LitheBanner(status: .info) {
            Text(message).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(usesChinese ? "打开插件管理" : "Open Plugin Management") {
                    model.showSettings(category: .plugins)
                }
                if model.pluginSnapshots.contains(where: \.hasChangesPendingRestart) {
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
                return usesChinese ? "语言服务已连接，Maven 配置应用中" : "Language service connected; applying Maven configuration"
            case .partiallyFailed(let failed, let total):
                return usesChinese
                    ? "部分模块失败（\(failed)/\(total)），语言服务仍可用"
                    : "Some modules failed (\(failed)/\(total)); language service remains available"
            case .idle, .complete:
                break
            }
        }
        switch status {
        case .starting: return usesChinese ? "正在启动" : "Starting"
        case .initializing: return usesChinese ? "正在初始化项目索引" : "Initializing project index"
        case .active: return usesChinese ? "运行中" : "Running"
        case .stopping: return usesChinese ? "正在停止" : "Stopping"
        case .disabled: return usesChinese ? "已关闭" : "Off"
        case .stopped:
            return usesChinese ? "按需启动，打开对应文件时运行" : "Starts on demand when a matching file is opened"
        case .error:
            if descriptor.id == "java" {
                return usesChinese
                    ? "启动失败，请检查 LSP 运行 JDK"
                    : "Failed to start; check the LSP runtime JDK"
            }
            return usesChinese
                ? "启动失败，请检查语言服务器配置"
                : "Failed to start; check the language server configuration"
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
