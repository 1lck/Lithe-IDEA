import SwiftUI

struct LanguageServerSetupView: View {
    @ObservedObject var tools: LanguageServerToolService

    let providers: [LanguageProviderDescriptor]
    let language: AppLanguage
    let chooseExecutable: (LanguageProviderDescriptor) -> URL?
    let openOfficialDownload: (URL) -> Void
    let configurationChanged: (String) -> Void
    let isEmbedded: Bool

    @State private var selectedProviderID: String
    @State private var executablePathDraft = ""
    @State private var validationMessage: String?

    init(
        tools: LanguageServerToolService,
        providers: [LanguageProviderDescriptor],
        initialProviderID: String?,
        language: AppLanguage,
        chooseExecutable: @escaping (LanguageProviderDescriptor) -> URL?,
        openOfficialDownload: @escaping (URL) -> Void,
        configurationChanged: @escaping (String) -> Void,
        isEmbedded: Bool = false
    ) {
        self.tools = tools
        self.providers = providers
        self.language = language
        self.chooseExecutable = chooseExecutable
        self.openOfficialDownload = openOfficialDownload
        self.configurationChanged = configurationChanged
        self.isEmbedded = isEmbedded
        let initialID = initialProviderID.flatMap { id in
            providers.contains(where: { $0.id == id }) ? id : nil
        } ?? providers.first?.id ?? ""
        _selectedProviderID = State(initialValue: initialID)
        _executablePathDraft = State(initialValue: tools.customExecutablePath(for: initialID) ?? "")
    }

    private var copy: LanguageServerSetupCopy {
        LanguageServerSetupCopy(language: language)
    }

    private var selectedDescriptor: LanguageProviderDescriptor? {
        providers.first { $0.id == selectedProviderID }
    }

    private var candidates: [RuntimeToolCandidate] {
        selectedDescriptor.map(tools.candidates(for:)) ?? []
    }

    private var resolvedExecutable: RuntimeToolCandidate? {
        candidates.first
    }

    private var installPlan: LanguageServerInstallPlan? {
        selectedDescriptor.map(tools.installPlan(for:))
    }

    private var installationState: LanguageServerInstallationState {
        selectedDescriptor.map { tools.installationState(for: $0.id) } ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            setupHeader
            Divider().overlay(LitheTheme.divider)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    providerPicker
                    detectionSection
                    pathSection
                    installSection
                }
                .padding(14)
            }
            .litheScrollViewChrome(hideHorizontal: true)
        }
        .frame(width: isEmbedded ? nil : 430, height: isEmbedded ? nil : 510)
        .frame(maxWidth: isEmbedded ? .infinity : nil, minHeight: isEmbedded ? 430 : nil)
        .background(LitheTheme.sidebar)
        .onChange(of: selectedProviderID) { _, providerID in
            executablePathDraft = tools.customExecutablePath(for: providerID) ?? ""
            validationMessage = nil
        }
    }

    private var setupHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.subtleSelection))
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(copy.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(LitheTheme.toolHeader)
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(copy.languageServer)
            Picker(copy.languageServer, selection: $selectedProviderID) {
                ForEach(providers) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.detectedExecutable)
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(resolvedExecutable == nil ? LitheTheme.warning : LitheTheme.success)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(resolvedExecutable == nil ? copy.notFound : copy.ready)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(resolvedExecutable?.executableURL.path ?? expectedCommands)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let source = resolvedExecutable?.source {
                    Text(source.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(LitheTheme.raised))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 7).fill(LitheTheme.raised.opacity(0.55)))

            ForEach(Array(candidates.dropFirst().prefix(2))) { candidate in
                HStack(spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(candidate.executableURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(candidate.source.displayName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle(copy.executablePath)
                Spacer(minLength: 0)
                Button(copy.useAutomatic) {
                    clearOverride()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
                .disabled(tools.customExecutablePath(for: selectedProviderID) == nil)
            }

            HStack(spacing: 7) {
                TextField(copy.pathPlaceholder, text: $executablePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button {
                    browseForExecutable()
                } label: {
                    Image(systemName: "folder")
                }
                .litheIconButton()
                .help(copy.chooseExecutable)
                Button(copy.savePath) {
                    savePath()
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(executablePathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(validationMessage ?? copy.pathHint)
                .font(.system(size: 10.5))
                .foregroundStyle(validationMessage == nil ? LitheTheme.secondaryText : LitheTheme.error)
                .lineLimit(2)
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(copy.installation)
            Text(copy.installationHint)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)

            HStack(spacing: 8) {
                Button {
                    installWithHomebrew()
                } label: {
                    HStack(spacing: 7) {
                        if case .installing = installationState {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "shippingbox")
                        }
                        Text(homebrewButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LithePrimaryButtonStyle())
                .disabled(!canInstallWithHomebrew)

                Button {
                    guard let url = installPlan?.officialDownloadURL else { return }
                    openOfficialDownload(url)
                } label: {
                    Label(copy.officialDownload, systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(installPlan?.officialDownloadURL == nil)
            }

            installationMessage
        }
    }

    @ViewBuilder
    private var installationMessage: some View {
        switch installationState {
        case .idle:
            if installPlan?.homebrewFormula != nil, !tools.isHomebrewAvailable() {
                statusMessage(copy.homebrewUnavailable, color: LitheTheme.warning)
            }
        case .installing:
            statusMessage(copy.installing, color: LitheTheme.accent)
        case .installed(let output):
            statusMessage(copy.installComplete(output), color: LitheTheme.success)
        case .failed(let message):
            statusMessage(message, color: LitheTheme.error)
        }
    }

    private func statusMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.raised.opacity(0.55)))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
    }

    private var expectedCommands: String {
        guard let commands = selectedDescriptor?.languageServerLaunch?.executableNames,
              !commands.isEmpty else { return copy.noLaunchCommand }
        return copy.expectedCommands(commands.joined(separator: ", "))
    }

    private var canInstallWithHomebrew: Bool {
        guard installPlan?.homebrewFormula != nil,
              tools.isHomebrewAvailable() else { return false }
        if case .installing = installationState { return false }
        return true
    }

    private var homebrewButtonTitle: String {
        guard let formula = installPlan?.homebrewFormula else { return copy.noHomebrewFormula }
        return copy.installWithHomebrew(formula)
    }

    private func browseForExecutable() {
        guard let descriptor = selectedDescriptor,
              let url = chooseExecutable(descriptor) else { return }
        executablePathDraft = url.path
        savePath()
    }

    private func savePath() {
        guard let descriptor = selectedDescriptor else { return }
        do {
            try tools.setCustomExecutablePath(executablePathDraft, for: descriptor)
            executablePathDraft = tools.customExecutablePath(for: descriptor.id) ?? executablePathDraft
            validationMessage = nil
            configurationChanged(descriptor.id)
        } catch {
            validationMessage = if let configurationError = error as? LanguageServerToolConfigurationError {
                copy.message(for: configurationError)
            } else {
                error.localizedDescription
            }
        }
    }

    private func clearOverride() {
        guard let descriptor = selectedDescriptor else { return }
        tools.clearCustomExecutablePath(for: descriptor.id)
        executablePathDraft = ""
        validationMessage = nil
        configurationChanged(descriptor.id)
    }

    private func installWithHomebrew() {
        guard let descriptor = selectedDescriptor else { return }
        Task {
            await tools.installWithHomebrew(descriptor)
            if case .installed = tools.installationState(for: descriptor.id) {
                configurationChanged(descriptor.id)
            }
        }
    }
}

private struct LanguageServerSetupCopy {
    let language: AppLanguage

    private var usesChinese: Bool { language == .simplifiedChinese }

    var title: String { usesChinese ? "语言服务器工具" : "Language Server Tools" }
    var subtitle: String { usesChinese ? "安装、探测并指定 LSP 可执行文件" : "Install, detect, and select LSP executables" }
    var languageServer: String { usesChinese ? "语言服务器" : "Language server" }
    var detectedExecutable: String { usesChinese ? "当前解析结果" : "Resolved executable" }
    var ready: String { usesChinese ? "可用" : "Ready" }
    var notFound: String { usesChinese ? "未找到可执行文件" : "Executable not found" }
    var executablePath: String { usesChinese ? "自定义路径" : "Custom path" }
    var useAutomatic: String { usesChinese ? "恢复自动探测" : "Use automatic detection" }
    var pathPlaceholder: String { usesChinese ? "选择或输入绝对路径" : "Choose or enter an absolute path" }
    var chooseExecutable: String { usesChinese ? "选择可执行文件" : "Choose executable" }
    var savePath: String { usesChinese ? "保存" : "Save" }
    var pathHint: String { usesChinese ? "保存后，下一次启动该 LSP 时使用此路径。" : "The next LSP session will use this path." }
    var installation: String { usesChinese ? "安装" : "Installation" }
    var installationHint: String {
        usesChinese
            ? "优先使用 Homebrew；没有可用 formula 或 Homebrew 时，从官方页面下载安装。"
            : "Homebrew is preferred. Use the official download when Homebrew or a formula is unavailable."
    }
    var officialDownload: String { usesChinese ? "官方下载" : "Official download" }
    var homebrewUnavailable: String { usesChinese ? "未找到 Homebrew，请使用官方下载或手动指定路径。" : "Homebrew was not found. Use the official download or choose an executable." }
    var installing: String { usesChinese ? "Homebrew 正在安装…" : "Installing with Homebrew..." }
    var noHomebrewFormula: String { usesChinese ? "无 Brew formula" : "No Brew formula" }
    var noLaunchCommand: String { usesChinese ? "Provider 未配置启动命令" : "No launch command is configured" }

    func expectedCommands(_ commands: String) -> String {
        usesChinese ? "等待探测：\(commands)" : "Expected: \(commands)"
    }

    func installWithHomebrew(_ formula: String) -> String {
        usesChinese ? "Brew 安装 \(formula)" : "Install \(formula)"
    }

    func installComplete(_ output: String) -> String {
        let firstLine = output.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? output
        return usesChinese ? "安装完成：\(firstLine)" : "Installed: \(firstLine)"
    }

    func message(for error: LanguageServerToolConfigurationError) -> String {
        switch error {
        case .executableRequired:
            usesChinese ? "请选择语言服务器可执行文件。" : error.localizedDescription
        case .executableInvalid(let path):
            usesChinese ? "该路径不是可执行文件：\(path)" : error.localizedDescription
        case .executableValidationFailed(let path, let message):
            usesChinese ? "语言服务器无法运行：\(path)\n\(message)" : error.localizedDescription
        case .homebrewUnavailable:
            usesChinese ? "Lithe 无法找到 Homebrew。" : error.localizedDescription
        case .homebrewUnsupported(let provider):
            usesChinese ? "\(provider) 没有已验证的 Homebrew formula。" : error.localizedDescription
        }
    }
}
