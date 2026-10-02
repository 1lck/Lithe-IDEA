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
                    if let phpNotice = phpNotice {
                        phpPluginNotice(phpNotice)
                    }
                    if projectLanguageServers.isEmpty && phpNotice == nil {
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
        Label(
            usesChinese ? "语言服务器配置加载异常，当前正在使用兼容配置。" : "Language server configuration is degraded; compatibility settings are in use.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(LitheTheme.warning)
    }

    private var projectLanguageServers: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .filter { descriptor in
                descriptor.id != "php" || phpPluginIsReady
            }
            .filter { descriptor in
                model.projectFiles.contains { descriptor.handles(fileURL: $0) }
            }
    }

    private var phpPluginSnapshot: PluginManagementSnapshot? {
        model.pluginSnapshots.first { $0.id == OfficialPluginCatalog.phpPluginID }
    }

    private var phpPluginIsReady: Bool {
        guard let snapshot = phpPluginSnapshot else { return false }
        return snapshot.isEnabled && !snapshot.requiresRestart && !snapshot.isQuarantined
    }

    private var hasPHPProjectFiles: Bool {
        model.projectFiles.contains { fileURL in
            let pathExtension = fileURL.pathExtension.lowercased()
            return ["php", "phtml"].contains(pathExtension)
                || fileURL.lastPathComponent.lowercased() == "composer.json"
        }
    }

    private var phpNotice: String? {
        guard hasPHPProjectFiles, !phpPluginIsReady else { return nil }
        guard let snapshot = phpPluginSnapshot else {
            return usesChinese
                ? "检测到 PHP 项目，请先在插件管理中下载并安装 PHP 支持。"
                : "This PHP project needs PHP Support. Download and install it from Plugin Management."
        }
        if snapshot.requiresRestart {
            return usesChinese
                ? "PHP 支持已安装，重启 Lithe 后才能在这里控制语言服务器。"
                : "PHP Support is installed. Restart Lithe before controlling its language server here."
        }
        if snapshot.isQuarantined {
            return usesChinese
                ? "PHP 支持因上次启动异常被隔离，请先在插件管理中重新启用。"
                : "PHP Support was quarantined after its previous session. Re-enable it from Plugin Management."
        }
        return usesChinese
            ? "PHP 支持插件已禁用，请先在插件管理中启用。"
            : "PHP Support is disabled. Enable it from Plugin Management first."
    }

    private func phpPluginNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "puzzlepiece.extension")
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(usesChinese ? "打开插件管理" : "Open Plugin Management") {
                model.showSettings(category: .plugins)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(LitheTheme.settingsSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .stroke(LitheTheme.divider, lineWidth: 1)
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
