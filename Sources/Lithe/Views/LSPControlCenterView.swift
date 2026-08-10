import SwiftUI

struct LSPControlCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    private let metricColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var copy: LSPControlCenterCopy {
        LSPControlCenterCopy(language: settings.language)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    globalControls
                    serverList
                    if let selected = selectedDescriptor {
                        serverDetail(selected)
                    } else {
                        emptyDetail
                    }
                    diagnosticLog
                }
                .padding(8)
            }
            .background(LitheTheme.editor)
        }
        .background(LitheTheme.editor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(copy.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer(minLength: 0)
            Button {
                model.isLSPControlCenterVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help(copy.hideControlCenter)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(LitheTheme.toolHeader)
    }

    private var globalControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(copy.currentProject)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(model.projectName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                statusPill(
                    title: activeServerCount > 0 ? copy.lspActive : copy.onDemand,
                    color: activeServerCount > 0 ? LitheTheme.success : LitheTheme.secondaryText
                )
            }

            HStack(spacing: 8) {
                Button {
                    model.restartLanguageServers()
                } label: {
                    Label(copy.restartAll, systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LithePrimaryButtonStyle())

                Button {
                    model.clearLanguageServerDiagnostics()
                } label: {
                    Label(copy.clearDiagnostics, systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }
        }
        .padding(10)
        .panelChrome()
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.languageServers)

            VStack(spacing: 1) {
                ForEach(languageServerDescriptors) { descriptor in
                    serverRow(descriptor)
                }
            }
        }
        .padding(10)
        .panelChrome()
    }

    private func serverRow(_ descriptor: LanguageProviderDescriptor) -> some View {
        let metrics = providerMetrics(for: descriptor)
        let isSelected = descriptor.id == selectedDescriptor?.id

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(metrics.status))
                .frame(width: 8, height: 8)
            providerIcon(for: descriptor)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Text(metrics.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(copy.title(for: metrics.status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor(metrics.status))
            Button {
                model.languageToolingSessions.stopLanguageServer(providerID: descriptor.id)
            } label: {
                Image(systemName: metrics.status == .active ? "stop" : "play")
            }
            .litheIconButton()
            .help(
                metrics.status == .active
                    ? copy.stopProvider(descriptor.displayName)
                    : copy.providerStartsOnDemand(descriptor.displayName)
            )
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .litheRowHover(isActive: isSelected, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
    }

    private func serverDetail(_ descriptor: LanguageProviderDescriptor) -> some View {
        let metrics = providerMetrics(for: descriptor)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                providerIcon(for: descriptor)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(descriptor.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        statusPill(title: copy.title(for: metrics.status), color: statusColor(metrics.status))
                    }
                    Text(metrics.workspacePath)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(metrics.version)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            HStack(spacing: 0) {
                summaryStat(copy.rootFiles, value: "\(metrics.fileCount)")
                summaryStat(copy.openFiles, value: "\(metrics.openFileCount)")
                summaryStat(copy.diagnostics, value: "\(metrics.diagnosticCount)")
            }

            LazyVGrid(columns: metricColumns, spacing: 8) {
                metricCard(title: copy.features, value: "\(metrics.featureCount)", color: LitheTheme.accent, progress: metrics.featureProgress)
                metricCard(title: copy.indexed, value: metrics.indexProgressText, color: LitheTheme.success, progress: metrics.indexProgress)
                metricCard(title: copy.errors, value: "\(metrics.errorCount)", color: LitheTheme.error, progress: metrics.errorProgress)
                metricCard(title: copy.warnings, value: "\(metrics.warningCount)", color: LitheTheme.warning, progress: metrics.warningProgress)
            }

            capabilityGrid(descriptor)
            configurationSection(descriptor)
        }
        .padding(10)
        .panelChrome()
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(copy.openSupportedFile)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(copy.matchingServerWillAppear)
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .panelChrome()
    }

    private var diagnosticLog: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle(copy.diagnostics)
                Spacer(minLength: 0)
                Text("\(allDiagnostics.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            if allDiagnostics.isEmpty {
                Text(copy.noLanguageServerDiagnostics)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(allDiagnostics.prefix(5).enumerated()), id: \.offset) { _, diagnostic in
                        Button {
                            model.openDiagnostic(diagnostic)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: diagnostic.severity.systemImage)
                                    .foregroundStyle(color(for: diagnostic.severity))
                                    .frame(width: 14)
                                Text(diagnostic.locationTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(LitheTheme.primaryText)
                                    .lineLimit(1)
                                Text(diagnostic.message)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .frame(height: 25)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                    }
                }
            }
        }
        .padding(10)
        .panelChrome()
    }

    private func capabilityGrid(_ descriptor: LanguageProviderDescriptor) -> some View {
        let rows: [(String, String, Bool)] = [
            (copy.definition, "arrowshape.turn.up.right", descriptor.capabilities.contains(.languageServer)),
            (copy.completion, "text.cursor", descriptor.capabilities.contains(.languageServer)),
            (copy.formatting, "text.alignleft", descriptor.capabilities.contains(.formatting)),
            (copy.testing, "checkmark.seal", descriptor.capabilities.contains(.testing)),
            (copy.debug, "ladybug", descriptor.capabilities.contains(.debugAdapter)),
            (copy.run, "play", descriptor.capabilities.contains(.run))
        ]

        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.capabilities)
            LazyVGrid(columns: metricColumns, spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 7) {
                        Image(systemName: row.1)
                            .frame(width: 15)
                        Text(row.0)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Toggle("", isOn: .constant(row.2))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .scaleEffect(0.62)
                            .allowsHitTesting(false)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(row.2 ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LitheTheme.raised.opacity(0.55))
                    )
                }
            }
        }
    }

    private func configurationSection(_ descriptor: LanguageProviderDescriptor) -> some View {
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.providerConfiguration)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "curlybraces.square")
                        .foregroundStyle(LitheTheme.accent)
                    Text(copy.rustOwnedConfiguration)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                configRow(title: copy.providerID, value: descriptor.id)
                configRow(title: copy.activation, value: copy.activationPolicy(descriptor.activationPolicy))
                configRow(title: copy.builtinCatalog, value: "rust/lithe-core/resources/lsp/language-providers.json")
                configRow(title: copy.projectOverride, value: projectLSPConfigPath)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(LitheTheme.raised.opacity(0.55))
            )

            Text(copy.configurationHint)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(2)
        }
    }

    private func configRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func metricCard(title: String, value: String, color: Color, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            ProgressView(value: min(max(progress, 0), 1))
                .tint(color)
                .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(LitheTheme.raised.opacity(0.58))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
    }

    private func summaryStat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
    }

    private func statusPill(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(color.opacity(0.16))
        )
    }

    private func providerIcon(for _: LanguageProviderDescriptor) -> some View {
        LitheIcon(kind: .generic, size: 17)
    }

    private func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .error: LitheTheme.error
        case .warning: LitheTheme.warning
        case .information: LitheTheme.accent
        case .hint: LitheTheme.secondaryText
        }
    }

    private func statusColor(_ status: LSPServerStatus) -> Color {
        switch status {
        case .active: LitheTheme.success
        case .indexing: LitheTheme.warning
        case .available: LitheTheme.accent
        case .stopped: LitheTheme.secondaryText
        case .error: LitheTheme.error
        }
    }

    private var languageServerDescriptors: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) }
    }

    private var selectedDescriptor: LanguageProviderDescriptor? {
        if let document = model.activeDocument,
           let descriptor = model.languageProviderCatalog.provider(for: document.url),
           descriptor.capabilities.contains(.languageServer) {
            return descriptor
        }
        return languageServerDescriptors.first
    }

    private var activeServerCount: Int {
        languageServerDescriptors.filter { providerMetrics(for: $0).status == .active }.count
    }

    private var projectLSPConfigPath: String {
        guard let workspaceURL = model.workspaceURL else {
            return ".lithe/lsp/language-providers.json"
        }
        return workspaceURL
            .appendingPathComponent(".lithe")
            .appendingPathComponent("lsp")
            .appendingPathComponent("language-providers.json")
            .path
    }

    private var allDiagnostics: [EditorDiagnostic] {
        model.editorDiagnostics.values
            .flatMap { $0 }
            .sorted {
                if $0.severity != $1.severity { return $0.severity.sortOrder < $1.severity.sortOrder }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.message < $1.message
            }
    }

    private func providerMetrics(for descriptor: LanguageProviderDescriptor) -> LSPProviderMetrics {
        let files = model.projectFiles.filter { descriptor.handles(fileURL: $0) }
        let openFiles = model.openDocuments.filter { descriptor.handles(fileURL: $0.url) }
        let diagnostics = model.editorDiagnostics
            .filter { descriptor.handles(fileURL: $0.key) }
            .values
            .flatMap { $0 }
        let features = model.languageToolingSessions.languageServerFeatures[descriptor.id] ?? []
        let status: LSPServerStatus
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .error
        } else if model.languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id) || !features.isEmpty {
            status = .active
        } else if !openFiles.isEmpty {
            status = .indexing
        } else if !files.isEmpty {
            status = .available
        } else {
            status = .stopped
        }

        let totalDiagnostics = max(diagnostics.count, 1)
        let errorCount = diagnostics.filter { $0.severity == .error }.count
        let warningCount = diagnostics.filter { $0.severity == .warning }.count
        let indexProgress = files.isEmpty ? 0 : min(1, Double(openFiles.count == 0 ? files.count / 2 : files.count) / Double(max(files.count, 1)))

        return LSPProviderMetrics(
            status: status,
            subtitle: files.isEmpty ? copy.noMatchingFiles : copy.matchingFiles(files.count),
            workspacePath: model.workspaceURL?.path ?? copy.noWorkspace,
            version: copy.providerVersion,
            fileCount: files.count,
            openFileCount: openFiles.count,
            diagnosticCount: diagnostics.count,
            errorCount: errorCount,
            warningCount: warningCount,
            featureCount: features.enabledFeatureCount,
            featureProgress: Double(features.enabledFeatureCount) / 11.0,
            indexProgress: indexProgress,
            errorProgress: Double(errorCount) / Double(totalDiagnostics),
            warningProgress: Double(warningCount) / Double(totalDiagnostics)
        )
    }

}

private enum LSPServerStatus {
    case active
    case indexing
    case available
    case stopped
    case error
}

private struct LSPControlCenterCopy {
    let language: AppLanguage

    private var usesChinese: Bool {
        language == .simplifiedChinese
    }

    var title: String { usesChinese ? "LSP 控制中心" : "LSP Control Center" }
    var hideControlCenter: String { usesChinese ? "隐藏 LSP 控制中心" : "Hide LSP Control Center" }
    var currentProject: String { usesChinese ? "当前项目：" : "Current project:" }
    var lspActive: String { usesChinese ? "LSP 运行中" : "LSP active" }
    var onDemand: String { usesChinese ? "按需启动" : "On demand" }
    var restartAll: String { usesChinese ? "全部重启" : "Restart all" }
    var clearDiagnostics: String { usesChinese ? "清空诊断" : "Clear diagnostics" }
    var languageServers: String { usesChinese ? "语言服务器" : "Language Servers" }
    var rootFiles: String { usesChinese ? "项目文件" : "Root files" }
    var openFiles: String { usesChinese ? "打开文件" : "Open files" }
    var diagnostics: String { usesChinese ? "诊断" : "Diagnostics" }
    var features: String { usesChinese ? "功能" : "Features" }
    var indexed: String { usesChinese ? "索引" : "Indexed" }
    var errors: String { usesChinese ? "错误" : "Errors" }
    var warnings: String { usesChinese ? "警告" : "Warnings" }
    var openSupportedFile: String { usesChinese ? "打开一个受支持的源码文件" : "Open a supported source file" }
    var matchingServerWillAppear: String {
        usesChinese ? "匹配的语言服务器会显示在这里。" : "The matching language server will appear here."
    }
    var noLanguageServerDiagnostics: String {
        usesChinese ? "暂无语言服务器诊断。" : "No language server diagnostics."
    }
    var capabilities: String { usesChinese ? "能力" : "Capabilities" }
    var definition: String { usesChinese ? "定义" : "Definition" }
    var completion: String { usesChinese ? "补全" : "Completion" }
    var formatting: String { usesChinese ? "格式化" : "Formatting" }
    var testing: String { usesChinese ? "测试" : "Testing" }
    var debug: String { usesChinese ? "调试" : "Debug" }
    var run: String { usesChinese ? "运行" : "Run" }
    var noMatchingFiles: String { usesChinese ? "没有匹配文件" : "No matching files" }
    var noWorkspace: String { usesChinese ? "未打开工作区" : "No workspace" }
    var providerVersion: String { usesChinese ? "兼容层" : "provider" }
    var providerConfiguration: String { usesChinese ? "Provider 配置" : "Provider Configuration" }
    var rustOwnedConfiguration: String {
        usesChinese ? "由 Rust LSP 配置加载" : "Loaded by Rust LSP configuration"
    }
    var providerID: String { usesChinese ? "Provider ID" : "Provider ID" }
    var activation: String { usesChinese ? "启动策略" : "Activation" }
    var builtinCatalog: String { usesChinese ? "内置 JSON" : "Built-in JSON" }
    var projectOverride: String { usesChinese ? "项目覆盖" : "Project override" }
    var configurationHint: String {
        usesChinese
            ? "语言、扩展名、能力、命令和平台覆盖只允许写入独立 LSP JSON，由 Rust 兼容层注册。"
            : "Languages, extensions, capabilities, commands, and platform overrides belong in standalone LSP JSON registered by Rust."
    }

    func matchingFiles(_ count: Int) -> String {
        if usesChinese { return "\(count) 个匹配文件" }
        return "\(count) matching file\(count == 1 ? "" : "s")"
    }

    func activationPolicy(_ policy: ToolingActivationPolicy) -> String {
        switch policy {
        case .always:
            usesChinese ? "始终启动" : "Always"
        case .onDemand:
            usesChinese ? "按需启动" : "On demand"
        }
    }

    func stopProvider(_ name: String) -> String {
        usesChinese ? "停止 \(name)" : "Stop \(name)"
    }

    func providerStartsOnDemand(_ name: String) -> String {
        usesChinese
            ? "\(name) 会在打开匹配文件时启动"
            : "\(name) starts when a matching file opens"
    }

    func title(for status: LSPServerStatus) -> String {
        if usesChinese {
            switch status {
            case .active: "运行中"
            case .indexing: "索引中"
            case .available: "可用"
            case .stopped: "已停止"
            case .error: "错误"
            }
        } else {
            switch status {
            case .active: "Running"
            case .indexing: "Indexing"
            case .available: "Available"
            case .stopped: "Stopped"
            case .error: "Error"
            }
        }
    }
}

private struct LSPProviderMetrics {
    let status: LSPServerStatus
    let subtitle: String
    let workspacePath: String
    let version: String
    let fileCount: Int
    let openFileCount: Int
    let diagnosticCount: Int
    let errorCount: Int
    let warningCount: Int
    let featureCount: Int
    let featureProgress: Double
    let indexProgress: Double
    let errorProgress: Double
    let warningProgress: Double

    var indexProgressText: String {
        "\(Int((indexProgress * 100).rounded()))%"
    }
}

private extension DiagnosticSeverity {
    var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .information: 2
        case .hint: 3
        }
    }
}

private extension LanguageServerFeatureSet {
    var enabledFeatureCount: Int {
        [
            .definition,
            .references,
            .implementation,
            .hover,
            .completion,
            .rename,
            .formatting,
            .codeActions,
            .completionResolve,
            .codeActionResolve,
            .executeCommand
        ].filter { contains($0) }.count
    }
}

private extension View {
    func panelChrome() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LitheTheme.sidebar)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
    }
}
