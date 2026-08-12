import SwiftUI

struct LSPControlCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var configuredProviderID: String?

    private var usesChinese: Bool { settings.language == .simplifiedChinese }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSummary
                    if projectLanguageServers.isEmpty {
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
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LitheTheme.editor)
        }
        .background(LitheTheme.editor)
    }

    private var header: some View {
        HStack {
            Text(usesChinese ? "语言支持" : "Language Support")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(LitheTheme.toolHeader)
    }

    private var projectSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.projectName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(usesChinese
                ? "仅显示当前项目使用的语言。关闭后会停止对应语言服务器并释放资源。"
                : "Only languages used by this project are shown. Turning one off stops its language server and releases its resources.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languageRow(_ descriptor: LanguageProviderDescriptor) -> some View {
        let status = serverStatus(for: descriptor)
        let isEnabled = !model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(statusDescription(for: descriptor, status: status))
                        .font(.system(size: 11))
                        .foregroundStyle(status == .error ? LitheTheme.error : LitheTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if hasConfiguration(for: descriptor) {
                    Button {
                        configuredProviderID = configuredProviderID == descriptor.id
                            ? nil
                            : descriptor.id
                    } label: {
                        LitheSystemIcon(systemImage: "gearshape")
                    }
                    .litheIconButton()
                    .help(usesChinese
                        ? "配置 \(descriptor.displayName) 语言服务器"
                        : "Configure \(descriptor.displayName) language server")
                    .accessibilityLabel(Text(usesChinese
                        ? "配置 \(descriptor.displayName) 语言服务器"
                        : "Configure \(descriptor.displayName) language server"))
                }
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { model.setLanguageServerEnabled($0, providerID: descriptor.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .lithePointer()
                .accessibilityLabel(Text(usesChinese
                    ? "启用 \(descriptor.displayName) 语言服务器"
                    : "Enable \(descriptor.displayName) language server"))
            }

            if configuredProviderID == descriptor.id, descriptor.id == "java" {
                Divider().overlay(LitheTheme.divider)
                VStack(alignment: .leading, spacing: 7) {
                    Text(usesChinese ? "LSP 运行 JDK" : "LSP Runtime JDK")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Menu {
                        if model.detectedJavaLanguageServerJDKs.isEmpty {
                            Text(usesChinese ? "未检测到 JDK" : "No JDKs detected")
                        } else {
                            ForEach(model.detectedJavaLanguageServerJDKs) { runtime in
                                Button {
                                    model.selectJavaLanguageServerJDK(runtime)
                                } label: {
                                    if isSelectedJavaRuntime(runtime) {
                                        Label(javaRuntimeTitle(runtime), systemImage: "checkmark")
                                    } else {
                                        Text(javaRuntimeTitle(runtime))
                                    }
                                }
                            }
                        }
                        Divider()
                        Button(usesChinese ? "重新检测" : "Detect Again") {
                            Task { await model.refreshJavaLanguageServerJDKs() }
                        }
                        Button(usesChinese ? "选择其他目录…" : "Choose Other Directory…") {
                            model.chooseJavaLanguageServerJDK()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedJavaRuntime.map(javaRuntimeTitle) ?? javaJDKDisplayPath)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(model.javaLanguageServerJDKPath.isEmpty
                                        ? LitheTheme.secondaryText
                                        : LitheTheme.primaryText)
                                if !model.javaLanguageServerJDKPath.isEmpty {
                                    Text(model.javaLanguageServerJDKPath)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.editor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(LitheTheme.panelBorder, lineWidth: 1)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .lithePointer()
                    Text(usesChinese
                        ? "仅用于启动 Java 语言服务器，不影响项目使用的 JDK。"
                        : "Used only to start the Java language server; it does not affect the project JDK.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(LitheTheme.sidebar)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(usesChinese ? "当前项目没有可配置的语言服务器" : "No configurable language servers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(usesChinese
                ? "识别到支持的源码语言后，会在这里显示对应设置。"
                : "Settings appear here when supported source languages are detected.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.vertical, 10)
    }

    private var degradedCatalogNotice: some View {
        Label(
            usesChinese ? "语言服务器配置加载异常，当前正在使用兼容配置。" : "Language server configuration is degraded; compatibility settings are in use.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.system(size: 11))
        .foregroundStyle(LitheTheme.warning)
    }

    private var projectLanguageServers: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .filter { descriptor in
                model.projectFiles.contains { descriptor.handles(fileURL: $0) }
            }
    }

    private func hasConfiguration(for descriptor: LanguageProviderDescriptor) -> Bool {
        descriptor.id == "java"
    }

    private var javaJDKDisplayPath: String {
        let path = model.javaLanguageServerJDKPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return path }
        return usesChinese ? "未配置" : "Not configured"
    }

    private var selectedJavaRuntime: JavaRuntimeCandidate? {
        model.detectedJavaLanguageServerJDKs.first(where: isSelectedJavaRuntime)
    }

    private func isSelectedJavaRuntime(_ runtime: JavaRuntimeCandidate) -> Bool {
        let selectedPath = model.javaLanguageServerJDKPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedPath.isEmpty else { return false }
        return URL(fileURLWithPath: runtime.homePath).standardizedFileURL.path
            == URL(fileURLWithPath: selectedPath).standardizedFileURL.path
    }

    private func javaRuntimeTitle(_ runtime: JavaRuntimeCandidate) -> String {
        runtime.displayName
    }

    private func serverStatus(for descriptor: LanguageProviderDescriptor) -> LSPServerStatus {
        LSPControlCenterPresenter.serverStatus(
            isDisabled: model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id),
            sessionState: model.languageToolingSessions.languageServerStates[descriptor.id]
        )
    }

    private func statusDescription(
        for descriptor: LanguageProviderDescriptor,
        status: LSPServerStatus
    ) -> String {
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
