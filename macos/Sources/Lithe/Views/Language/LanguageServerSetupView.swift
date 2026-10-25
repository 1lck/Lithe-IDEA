import LitheCoreContracts
import LitheLanguageIntelligenceModule
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

    private var executableVerificationState: LanguageServerExecutableVerificationState {
        guard let selectedDescriptor else { return .unavailable }
        return tools.executableVerificationState(for: selectedDescriptor)
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
        .onChange(of: selectedProviderID) { providerID in
            executablePathDraft = tools.customExecutablePath(for: providerID) ?? ""
            validationMessage = nil
        }
        .task(id: selectedProviderID) {
            guard let descriptor = selectedDescriptor else { return }
            await tools.refreshCandidates(for: descriptor)
        }
    }

    private var setupHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(LitheTheme.uiFont(size: 15, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.subtleSelection))
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.title)
                    .font(LitheTheme.uiFont(size: 13.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(copy.subtitle)
                    .font(LitheTheme.uiFont(size: 10.5))
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
            LitheSettingsSelect(selection: $selectedProviderID, options: providers.map(\.id), width: 200, accessibilityLabel: copy.languageServer, title: { id in providers.first { $0.id == id }?.displayName ?? id })


            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.detectedExecutable)
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(executableStatusColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(executableStatusTitle)
                        .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(resolvedExecutable?.executableURL.path ?? expectedCommands)
                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let source = resolvedExecutable?.source {
                    Text(source.displayName)
                        .font(LitheTheme.uiFont(size: 9.5, weight: .medium))
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
                        .font(LitheTheme.uiFont(size: 9))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(candidate.executableURL.path)
                        .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(candidate.source.displayName)
                        .font(LitheTheme.uiFont(size: 9.5))
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
                .buttonStyle(.litheNoPress)
                .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.accent)
                .disabled(tools.customExecutablePath(for: selectedProviderID) == nil)
            }

            HStack(spacing: 7) {
                TextField(copy.pathPlaceholder, text: $executablePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
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
                .buttonStyle(LitheActionButtonStyle())
                .disabled(executablePathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(validationMessage ?? copy.pathHint)
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(validationMessage == nil ? LitheTheme.secondaryText : LitheTheme.error)
                .lineLimit(2)
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(copy.installation)
            Text(copy.installationHint)
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)

            HStack(spacing: LitheTheme.ActionButton.spacing) {
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
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .disabled(!canInstallWithHomebrew)

                Button {
                    guard let url = installPlan?.officialDownloadURL else { return }
                    openOfficialDownload(url)
                } label: {
                    Label(copy.officialDownload, systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LitheActionButtonStyle())
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
            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.raised.opacity(0.55)))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(LitheTheme.uiFont(size: 10.5, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
    }

    private var expectedCommands: String {
        guard let commands = selectedDescriptor?.languageServerLaunch?.executableNames,
              !commands.isEmpty else { return copy.noLaunchCommand }
        return copy.expectedCommands(commands.joined(separator: ", "))
    }

    private var executableStatusTitle: String {
        switch executableVerificationState {
        case .unavailable:
            copy.notFound
        case .foundUnverified:
            copy.executableFoundUnverified
        case .executableVerified:
            copy.executableVerified
        }
    }

    private var executableStatusColor: Color {
        switch executableVerificationState {
        case .unavailable:
            LitheTheme.warning
        case .foundUnverified:
            LitheTheme.accent
        case .executableVerified:
            LitheTheme.success
        }
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
        Task {
            do {
                try await tools.setCustomExecutablePath(executablePathDraft, for: descriptor)
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
    }

    private func clearOverride() {
        guard let descriptor = selectedDescriptor else { return }
        tools.clearCustomExecutablePath(for: descriptor.id)
        executablePathDraft = ""
        validationMessage = nil
        configurationChanged(descriptor.id)
        Task { await tools.refreshCandidates(for: descriptor) }
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


    var title: String { language.localizedString("native.inline.languageServerTools") }
    var subtitle: String { language.localizedString("native.inline.installDetectAndSelectLspExecutables") }
    var languageServer: String { language.localizedString("native.inline.languageServer") }
    var detectedExecutable: String { language.localizedString("native.inline.resolvedExecutable") }
    var executableFoundUnverified: String {
        language.localizedString("native.inline.executableFoundNotVerified")
    }
    var executableVerified: String {
        language.localizedString("native.inline.executableVerified")
    }
    var notFound: String { language.localizedString("native.inline.executableNotFound") }
    var executablePath: String { language.localizedString("native.inline.customPath") }
    var useAutomatic: String { language.localizedString("native.inline.useAutomaticDetection") }
    var pathPlaceholder: String { language.localizedString("native.inline.chooseOrEnterAnAbsolutePath") }
    var chooseExecutable: String { language.localizedString("native.inline.chooseExecutable") }
    var savePath: String { language.localizedString("native.inline.save") }
    var pathHint: String { language.localizedString("native.inline.theNextLspSessionWillUseThisPath") }
    var installation: String { language.localizedString("native.inline.installation") }
    var installationHint: String {
        language.localizedString("native.inline.homebrewIsPreferredUseTheOfficialDownloadWhenHomebrewOrAFormulaIsUnavailabl")
    }
    var officialDownload: String { language.localizedString("native.inline.officialDownload") }
    var homebrewUnavailable: String { language.localizedString("native.inline.homebrewWasNotFoundUseTheOfficialDownloadOrChooseAnExecutable") }
    var installing: String { language.localizedString("native.inline.installingWithHomebrew") }
    var noHomebrewFormula: String { language.localizedString("native.inline.noBrewFormula") }
    var noLaunchCommand: String { language.localizedString("native.inline.noLaunchCommandIsConfigured") }

    func expectedCommands(_ commands: String) -> String {
        language.localizedFormat("native.inline.expectedArg1", String(describing: commands))
    }

    func installWithHomebrew(_ formula: String) -> String {
        language.localizedFormat("native.inline.installArg1", String(describing: formula))
    }

    func installComplete(_ output: String) -> String {
        let firstLine = output.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? output
        return language.localizedFormat("native.inline.installedArg1", String(describing: firstLine))
    }

    func message(for error: LanguageServerToolConfigurationError) -> String {
        switch error {
        case .executableRequired:
            language.localizedString("native.inline.executableRequired")
        case .executableInvalid(let path):
            language.localizedFormat("native.inline.executableInvalid", path)
        case .executableValidationFailed(let path, let message):
            language.localizedFormat("native.inline.executableValidationFailed", path, message)
        case .homebrewUnavailable:
            language.localizedString("native.inline.homebrewUnavailable")
        case .homebrewUnsupported(let provider):
            language.localizedFormat("native.inline.homebrewUnsupported", provider)
        }
    }
}
