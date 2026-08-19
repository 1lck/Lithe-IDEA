import Foundation

@MainActor
extension AppModel {
    func chooseLanguageServerExecutable(providerName: String) -> URL? {
        platformUI.chooseFile(
            title: settings.language == .simplifiedChinese
                ? "选择 \(providerName) 语言服务器"
                : "Choose \(providerName) language server",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        )
    }

    func openLanguageServerDownload(_ url: URL) {
        platformUI.open(url)
    }

    func languageServerToolConfigurationDidChange(providerID: String) {
        languageToolingFeature.toolConfigurationDidChange(providerID: providerID)
    }

    func isLanguageServerDisabledInCurrentWorkspace(providerID: String) -> Bool {
        languageToolingFeature.isDisabled(providerID)
    }

    func setLanguageServerEnabled(_ enabled: Bool, providerID: String) {
        if enabled {
            languageToolingFeature.setEnabled(true, providerID: providerID)
        } else {
            languageToolingFeature.setEnabled(false, providerID: providerID)
        }
    }

    var javaLanguageServerJDKPath: String {
        settings.javaLanguageServerJDKPath
    }

    var detectedJavaLanguageServerJDKs: [JavaRuntimeCandidate] {
        runtimeFeature.javaLanguageServerRuntimes
    }

    func selectJavaLanguageServerJDK(_ runtime: JavaRuntimeCandidate) {
        applyJavaLanguageServerJDKPath(runtime.homePath)
    }

    func refreshJavaLanguageServerJDKs() async {
        await runtimeFeature.refreshAvailableRuntimes()
    }

    func useAutomaticJavaLanguageServerJDK() {
        applyJavaLanguageServerJDKPath("")
    }

    func chooseJavaLanguageServerJDK() {
        guard let url = platformUI.chooseDirectory(
            title: settings.language == .simplifiedChinese ? "选择 LSP 运行 JDK" : "Choose LSP Runtime JDK",
            prompt: settings.language == .simplifiedChinese ? "选择" : "Choose"
        ) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let runtime = await self.services.projectRuntimeService
                .inspectJavaLanguageServerRuntime(atPath: url.path) else {
                self.showNotification(self.settings.language == .simplifiedChinese
                    ? "所选目录不是有效的 JDK Home"
                    : "The selected directory is not a valid JDK Home")
                return
            }
            guard runtime.supportsJDTLS else {
                self.showNotification(self.settings.language == .simplifiedChinese
                    ? "JDTLS 需要 JDK 17 或更高版本；所选版本为 \(runtime.version)"
                    : "JDTLS requires JDK 17 or newer; the selected version is \(runtime.version)")
                return
            }
            self.applyJavaLanguageServerJDKPath(url.standardizedFileURL.path)
        }
    }

    func disableLanguageServerForCurrentWorkspace(providerID: String) {
        languageToolingFeature.setEnabled(false, providerID: providerID)
    }

    func prepareJavaLanguageServerRuntimeIfNeeded(for document: EditorDocument) -> Bool {
        let path = settings.javaLanguageServerJDKPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if services.projectRuntimeService.isJavaLanguageServerRuntimePrepared(overridePath: path) {
            return true
        }
        guard javaLanguageServerRuntimePreparationPath != path else { return false }

        javaLanguageServerRuntimePreparationTask?.cancel()
        javaLanguageServerRuntimePreparationPath = path
        javaLanguageServerRuntimePreparationTask = Task { [weak self, weak document] in
            guard let self, let document else { return }
            await self.services.projectRuntimeService.prepareJavaLanguageServerRuntime(
                overridePath: path
            )
            guard !Task.isCancelled,
                  self.javaLanguageServerRuntimePreparationPath == path else { return }
            self.javaLanguageServerRuntimePreparationTask = nil
            self.javaLanguageServerRuntimePreparationPath = nil
            _ = self.activateLanguageServerIfAvailable(for: document)
        }
        return false
    }

    private func applyJavaLanguageServerJDKPath(_ path: String) {
        languageToolingFeature.selectJavaJDK(path)
    }
}
