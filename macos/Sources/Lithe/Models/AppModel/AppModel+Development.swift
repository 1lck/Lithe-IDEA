import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

@MainActor
extension AppModel {
    func toggleSpringEndpoints() {
        isSpringVisible.toggle()
        guard isSpringVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
    }

    func openSpringEndpoint(_ endpoint: SpringEndpoint) {
        navigateToEditorLocation(
            url: endpoint.url,
            line: max(0, endpoint.line - 1),
            utf16Column: max(0, endpoint.column - 1)
        )
    }

    func toggleRun() {
        isRunVisible.toggle()
        guard isRunVisible else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await activateExecutionModule() != nil else { return }
            if let workspaceURL {
                await loadProjectServices(at: workspaceURL, files: projectFiles)
            }
        }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isDebugVisible = false
    }

    func toggleMaven() {
        guard hasMavenProject else {
            showNotification("No Maven project was detected in this workspace")
            isMavenVisible = false
            return
        }
        isMavenVisible.toggle()
        guard isMavenVisible else { return }
        Task { [weak self] in
            guard let self, await activateExecutionModule() != nil,
                  let workspaceURL else { return }
            await loadProjectServices(at: workspaceURL, files: projectFiles)
        }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        guard let workspaceURL else { return }
        Task { [weak self] in
            guard let self else { return }
            let capability = await self.activateExecutionModule()
            if capability?.mavenFeature.project == nil {
                await self.loadProjectServices(at: workspaceURL, files: self.projectFiles)
            }
        }
    }

    func runMaven(
        phase: MavenLifecyclePhase,
        module: MavenModule?
    ) {
        isMavenVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.run(phase: phase, module: module)
        }
    }

    func runMavenGoal(_ goal: String, module: MavenModule?) {
        isMavenVisible = true
        Task { [weak self] in
            guard let feature = await self?.activateExecutionModule()?.mavenFeature else { return }
            feature.runCustomGoal(goal, module: module)
        }
    }

    func stopMaven() {
        mavenFeatureIfActive?.stop()
    }

    func openMavenIssue(_ issue: MavenBuildIssue) {
        guard let fileURL = issue.fileURL,
              workspaceFeature.fileExists(at: fileURL) else { return }
        navigateToEditorLocation(
            url: fileURL.standardizedFileURL,
            line: max(0, (issue.line ?? 1) - 1),
            utf16Column: max(0, (issue.column ?? 1) - 1)
        )
    }

    /// 打开源码文件并定位到指定行/列(供构建输出、运行堆栈等可点击文本跳转)。
    func openSourceLocation(url: URL, line: Int, column: Int?) {
        guard workspaceFeature.fileExists(at: url) else { return }
        navigateToEditorLocation(
            url: url.standardizedFileURL,
            line: max(0, line - 1),
            utf16Column: max(0, (column ?? 1) - 1)
        )
    }

    func toggleProblems() {
        isProblemsVisible.toggle()
        guard isProblemsVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
    }

    func openDiagnostic(_ diagnostic: EditorDiagnostic) {
        guard workspaceFeature.fileExists(at: diagnostic.fileURL) else { return }
        navigateToEditorLocation(
            url: diagnostic.fileURL.standardizedFileURL,
            line: diagnostic.line,
            utf16Column: diagnostic.utf16Column
        )
    }

    func selectRunConfiguration(_ configuration: RunConfiguration) {
        runFeatureIfActive?.select(configuration)
    }

    func openRunConfiguration(relativePath: String?) {
        guard let workspaceURL else { return }
        let url = workspaceURL.appendingPathComponent(relativePath ?? ".lithe/run/generated.json")
        guard workspaceFeature.fileExists(at: url) else { return }
        openFile(url)
    }

    func runSelectedConfiguration() {
        Task { [weak self] in await self?.runSelectedConfigurationAfterActivation() }
    }

    private func runSelectedConfigurationAfterActivation() async {
        guard let runFeature = await activateExecutionModule()?.runFeature else { return }
        guard runFeature.configurationStatus == .ready else {
            runFeature.requestRunConfigurationGeneration(intent: .run)
            return
        }
        guard let configuration = runFeature.selectedConfiguration else { return }
        if !(await activateLanguageRunExtensionIfNeeded(
            for: configuration,
            currentFileURL: activeDocument?.url,
            runFeature: runFeature
        )) {
            return
        }
        if configuration.usesCurrentEditorFile,
           let activeDocument,
           activeDocument.isDirty {
            do {
                let previousText = activeDocument.savedText
                try saveDocument(activeDocument)
                recordSave(activeDocument, previousText: previousText)
            } catch {
                showNotification("Could not save \(activeDocument.url.lastPathComponent)")
                return
            }
        }
        runFeature.runSelected(currentFileURL: activeDocument?.url)
        isRunVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isMavenVisible = false
        isDebugVisible = false
    }

    func restartSelectedRun() {
        isRunVisible = true
        Task { [weak self] in
            guard let self,
                  let runFeature = await activateExecutionModule()?.runFeature else { return }
            guard let configuration = runFeature.lastConfiguration else { return }
            if !(await activateLanguageRunExtensionIfNeeded(
                for: configuration,
                currentFileURL: runFeature.lastRunFileURL,
                runFeature: runFeature
            )) {
                return
            }
            runFeature.restart()
        }
    }

    func startRunConfiguration(_ configuration: RunConfiguration) {
        Task { [weak self] in
            guard let self,
                  let runFeature = await activateExecutionModule()?.runFeature,
                  await activateLanguageRunExtensionIfNeeded(
                      for: configuration,
                      currentFileURL: activeDocument?.url,
                      runFeature: runFeature
                  ) else { return }
            runFeature.startConfiguration(configuration)
        }
    }

    func runAllServiceConfigurations() {
        Task { [weak self] in
            guard let self,
                  let runFeature = await activateExecutionModule()?.runFeature else { return }
            for configuration in runFeature.configurations where configuration.execution == .service {
                guard await activateLanguageRunExtensionIfNeeded(
                    for: configuration,
                    currentFileURL: nil,
                    runFeature: runFeature
                ) else { return }
            }
            runFeature.runAllServices()
        }
    }

    func stopSelectedRun() {
        runFeatureIfActive?.stop()
    }

    private func activateLanguageRunExtensionIfNeeded(
        for fileURL: URL,
        runFeature: RunFeatureModel
    ) async -> Bool {
        guard let ownership = services.pluginCatalog.languageSupport(for: fileURL) else {
            return true
        }
        return await activateLanguageRunExtension(
            ownership.declaration,
            runFeature: runFeature
        )
    }

    private func activateLanguageRunExtensionIfNeeded(
        for configuration: RunConfiguration,
        currentFileURL: URL?,
        runFeature: RunFeatureModel
    ) async -> Bool {
        if configuration.usesCurrentEditorFile {
            guard let currentFileURL else { return true }
            return await activateLanguageRunExtensionIfNeeded(
                for: currentFileURL,
                runFeature: runFeature
            )
        }
        guard let ownership = services.pluginCatalog.languageSupports[
            configuration.kind.providerID
        ] else {
            return true
        }
        return await activateLanguageRunExtension(
            ownership.declaration,
            runFeature: runFeature
        )
    }

    private func activateLanguageRunExtension(
        _ support: LanguageSupportDeclaration,
        runFeature: RunFeatureModel
    ) async -> Bool {
        guard support.executionModuleID != nil else {
            showNotification("\(support.displayName) does not provide project execution")
            return false
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(
                .languageExecutionExtension(support.id)
            )
            guard let provider = value as? any LanguageRunExtensionProviding,
                  runFeature.registerLanguageRunExtension(provider, support: support) else {
                showNotification("\(support.displayName) returned an invalid execution provider")
                return false
            }
            return true
        } catch {
            showNotification(error.localizedDescription)
            return false
        }
    }

    func toggleDebug() {
        isDebugVisible.toggle()
        guard isDebugVisible else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await activateExecutionModule() != nil else { return }
            if let workspaceURL {
                await loadProjectServices(at: workspaceURL, files: projectFiles)
            }
            _ = await activateDebugModule()
        }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func startDebugging() {
        Task { [weak self] in await self?.startDebuggingAfterActivation() }
    }

    private func startDebuggingAfterActivation() async {
        guard let execution = await activateExecutionModule(),
              let debug = await activateDebugModule() else { return }
        let runFeature = execution.runFeature
        let debugFeature = debug.javaFeature
        javaFeature.configureRuntime(
            mavenFeature: execution.mavenFeature,
            debugFeature: debugFeature
        )
        if let document = activeDocument,
           languageProviderCatalog.provider(for: document.url)?
               .capabilities.contains(.debugAdapter) == true {
            startGenericDebugging(document)
            return
        }
        if debugFeature.targetKind == .currentFile,
           let document = activeDocument,
           languageProviderCatalog.provider(for: document.url)?.id != "java" {
            let language = languageProviderCatalog.provider(for: document.url)?.displayName
                ?? "This file type"
            showNotification("\(language) debugging is not available on this machine")
            isDebugVisible = true
            return
        }
        if debugFeature.targetKind == .runConfiguration,
           runFeature.configurationStatus != .ready {
            runFeature.requestRunConfigurationGeneration(intent: .debug)
            return
        }
        if runFeature.blockingToolchainDiagnostic != nil {
            isRunVisible = true
            isDebugVisible = false
            isGitLogVisible = false
            isTerminalVisible = false
            isReferencesVisible = false
            isProblemsVisible = false
            isMavenVisible = false
            return
        }
        guard javaFeature.startDebugging(
            currentDocument: activeDocument,
            workspaceURL: workspaceURL,
            runFeature: runFeature,
            saveDocument: { [weak self] document in try self?.saveDocument(document) },
            recordSave: { [weak self] document, previousText in
                self?.recordSave(document, previousText: previousText)
            }
        ) else { return }
        isDebugVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func toggleTests() {
        isTestsVisible.toggle()
        guard isTestsVisible else { return }
        Task { [weak self] in _ = await self?.activateExecutionModule() }
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        guard let workspaceURL else { return }
        Task { [weak self] in
            guard let self,
                  let execution = await activateExecutionModule(),
                  await activateLanguageTestExtensionsIfNeeded(
                      for: projectFiles,
                      testService: execution.tests
                  ) else { return }
            execution.tests.discover(workspaceURL: workspaceURL, files: projectFiles)
        }
    }

    func refreshTests() {
        guard let workspaceURL else { return }
        Task { [weak self] in
            guard let self,
                  let execution = await activateExecutionModule(),
                  await activateLanguageTestExtensionsIfNeeded(
                      for: projectFiles,
                      testService: execution.tests
                  ) else { return }
            execution.tests.discover(workspaceURL: workspaceURL, files: projectFiles)
        }
    }

    func runTest(providerID: String, scope: LanguageTestScope) {
        guard let workspaceURL else { return }
        isTestsVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        Task { [weak self] in
            guard let self, let execution = await activateExecutionModule() else { return }
            if let ownership = services.pluginCatalog.languageSupports[providerID],
               !(await activateLanguageTestExtension(
                   ownership.declaration,
                   testService: execution.tests
               )) {
                return
            }
            _ = execution.tests.run(
                providerID: providerID,
                scope: scope,
                workspaceURL: workspaceURL,
                projectFiles: projectFiles
            )
        }
    }

    private func activateLanguageTestExtensionsIfNeeded(
        for files: [URL],
        testService: LanguageTestService
    ) async -> Bool {
        let supports = services.pluginCatalog.languageSupports(
            recognizingProjectFileNames: files.map(\.lastPathComponent)
        )
        for ownership in supports where ownership.declaration.testingModuleID != nil {
            guard await activateLanguageTestExtension(
                ownership.declaration,
                testService: testService
            ) else { return false }
        }
        return true
    }

    private func activateLanguageTestExtension(
        _ support: LanguageSupportDeclaration,
        testService: LanguageTestService
    ) async -> Bool {
        guard support.testingModuleID != nil else {
            showNotification("\(support.displayName) does not provide test execution")
            return false
        }
        do {
            let value = try await services.moduleRuntime.activateCapability(
                .languageTestingExtension(support.id)
            )
            guard let provider = value as? any LanguageTestExtensionProviding,
                  testService.registerLanguageTestExtension(provider, support: support) else {
                showNotification("\(support.displayName) returned an invalid test provider")
                return false
            }
            return true
        } catch {
            showNotification(error.localizedDescription)
            return false
        }
    }

    func stopTests() {
        languageTestServiceIfActive?.stop()
    }

    func stopDebugging() {
        if genericDebugFeatureIfActive?.providerID != nil {
            genericDebugFeatureIfActive?.stop()
        } else {
            debugFeatureIfActive?.stop()
        }
    }

    func toggleDebugBreakpointAtCaret() {
        guard let document = activeDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL else {
            showNotification("Place the caret in a source file to set a breakpoint")
            return
        }
        toggleDebugBreakpoint(fileURL: document.url, line: caret.line + 1)
    }

    func toggleDebugBreakpoint(fileURL: URL, line: Int) {
        if languageProviderCatalog.provider(for: fileURL)?
            .capabilities.contains(.debugAdapter) == true {
            Task { [weak self] in
                guard let feature = await self?.activateDebugModule()?.genericFeature else { return }
                feature.toggleBreakpoint(fileURL: fileURL, line: line)
            }
        } else if javaFeature.supportsLegacyDebugging(fileURL: fileURL) {
            javaFeature.toggleDebugBreakpoint(at: fileURL, line: line, documents: openDocuments)
        } else {
            showNotification("Debugging is not supported for this file type")
        }
    }

    var prefersGenericDebugUI: Bool {
        if genericDebugFeatureIfActive?.providerID != nil { return true }
        guard let document = activeDocument else { return false }
        // Never show the Java/JDB panel for another language. A configured
        // Provider may still be unavailable locally; the generic panel can
        // then present the Provider's installation error without leaking a
        // Java-specific workflow into that project.
        guard let descriptor = languageProviderCatalog.provider(for: document.url) else {
            return true
        }
        return descriptor.id != "java"
            || descriptor.capabilities.contains(.debugAdapter)
    }

    private func startGenericDebugging(_ document: EditorDocument) {
        Task { [weak self] in await self?.startGenericDebuggingAfterActivation(document) }
    }

    private func startGenericDebuggingAfterActivation(_ document: EditorDocument) async {
        guard let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url),
              let runFeature = await activateExecutionModule()?.runFeature,
              let genericDebugFeature = await activateDebugModule()?.genericFeature else {
            showNotification("No language provider is available for this file")
            return
        }
        if document.isDirty {
            do {
                let previousText = document.savedText
                try saveDocument(document)
                recordSave(document, previousText: previousText)
            } catch {
                showNotification("Could not save \(document.url.lastPathComponent)")
                return
            }
        }
        let configuration: DebugLaunchConfiguration
        do {
            configuration = try debugLaunchConfigurationResolver.resolve(
                provider: provider,
                documentURL: document.url,
                workspaceURL: workspaceURL,
                configurations: runFeature.configurations,
                selectedConfiguration: runFeature.selectedConfiguration,
                options: { [runFeature] in runFeature.options(for: $0) }
            )
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        guard genericDebugFeature.start(
            fileURL: document.url,
            rootURL: workspaceURL,
            configuration: configuration
        ) else {
            showNotification(genericDebugFeature.errorMessage ?? "Could not start debugging")
            isDebugVisible = true
            return
        }
        isDebugVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func goToDefinition() {
        if let document = activeDocument, let caret = editorCaret {
            let springLocations = springFeature.navigationLocations(
                for: document.url,
                line: caret.line
            )
            if !springLocations.isEmpty {
                presentGenericNavigationValues(
                    springLocations,
                    kind: .definitions,
                    navigateToSingleResult: true,
                    providerID: nil
                )
                return
            }
        }
        guard languageServerFeatureIsReady(
            .definition,
            unsupportedMessage: "Definition navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(method: "textDocument/definition", kind: .definitions)
    }

    func goToUsages() {
        guard languageServerFeatureIsReady(
            .references,
            unsupportedMessage: "Reference navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleResult: true
        )
    }

    func goToImplementation() {
        guard languageServerFeatureIsReady(
            .implementation,
            unsupportedMessage: "Implementation navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    func navigateToSymbol(line: Int, utf16Column: Int, in fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        guard languageProviderCatalog.provider(for: normalizedURL)?.capabilities.contains(.languageServer) == true
        else { return }
        editorCaret = EditorCaret(
            url: normalizedURL,
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
        if (languageToolingSessionsIfActive?.features(for: normalizedURL).contains(.definition) == true) {
            performGenericNavigation(
                method: "textDocument/definition",
                kind: .definitions,
                fallbackToImplementationsIfSelf: true
            )
        }
    }

    func findReferences() {
        guard languageServerFeatureIsReady(
            .references,
            unsupportedMessage: "Reference navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleResult: false
        )
    }

    func findJavaImplementations(line: Int, utf16Column: Int, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: line,
            utf16Column: utf16Column
        )
        guard languageServerFeatureIsReady(
            .implementation,
            unsupportedMessage: "Implementation navigation is not supported by this language server"
        ) else { return }
        performGenericNavigation(
            method: "textDocument/implementation",
            kind: .implementations,
            navigateToSingleResult: false
        )
    }

    func resolveJavaNavigation(_ marker: JavaImplementationMarker, in fileURL: URL) {
        guard !languageNavigationState.isLoading,
              let sessions = languageToolingSessionsIfActive,
              let provider = languageProviderCatalog.provider(for: fileURL) else { return }
        guard !isJavaLanguageServerPreparing(for: fileURL) else {
            showJavaLanguageServerPreparingNotification()
            return
        }
        let kind: LanguageNavigationResultKind = marker.direction == .down
            ? .implementations
            : .definitions
        let operationID = beginLanguageNavigation(providerID: provider.id, kind: kind)
        do {
            try sessions.resolveJavaNavigation(
                fileURL: fileURL,
                marker: marker.sharedMarker
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationState.owns(operationID: operationID) else { return }
                switch result {
                case .success(let locations):
                    self.presentGenericNavigationValues(
                        locations,
                        kind: kind,
                        navigateToSingleResult: true,
                        providerID: provider.id
                    )
                case .failure(let error):
                    self.languageNavigationState = .idle
                    self.showNotification(error.localizedDescription)
                }
            }
        } catch {
            if languageNavigationState.owns(operationID: operationID) {
                languageNavigationState = .idle
            }
            showNotification(error.localizedDescription)
        }
    }

    func navigate(to location: LanguageNavigationLocation) {
        isImplementationChooserVisible = false
        navigate(
            to: EditorNavigationLocation(
                url: location.url,
                line: location.line,
                utf16Column: location.utf16Column,
                isReadOnly: location.isReadOnly,
                displayPath: location.displayPath,
                virtualProviderID: location.url.isFileURL ? nil : languageNavigationState.providerID
            ),
            recordsHistory: true
        )
    }

    var canNavigateBack: Bool { navigationHistoryFeature.canNavigateBack }
    var canNavigateForward: Bool { navigationHistoryFeature.canNavigateForward }

    func navigateBack() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateBack(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateForward() {
        let historySnapshot = navigationHistoryFeature.snapshot()
        guard let location = navigationHistoryFeature.navigateForward(
            from: currentEditorNavigationLocation()
        ) else { return }
        navigate(to: location, recordsHistory: false) { [weak self] in
            self?.navigationHistoryFeature.restore(historySnapshot)
        }
    }

    func navigateToEditorLocation(
        url: URL,
        line: Int,
        utf16Column: Int,
        isReadOnly: Bool = false,
        displayPath: String? = nil,
        selectsWholeLine: Bool = false
    ) {
        navigate(
            to: EditorNavigationLocation(
                url: url,
                line: line,
                utf16Column: utf16Column,
                isReadOnly: isReadOnly,
                displayPath: displayPath,
                virtualProviderID: nil,
                selectsWholeLine: selectsWholeLine
            ),
            recordsHistory: true
        )
    }

    private func navigate(
        to location: EditorNavigationLocation,
        recordsHistory: Bool,
        onFailure: (() -> Void)? = nil
    ) {
        let departure = recordsHistory ? currentEditorNavigationLocation() : nil
        guard location.url.isFileURL else {
            if let existing = openDocuments.first(where: { $0.url == location.url }) {
                activeDocumentID = existing.id
                if recordsHistory {
                    navigationHistoryFeature.recordJump(from: departure, to: location)
                }
                editorNavigationTarget = EditorNavigationTarget(
                    url: location.url,
                    line: location.line,
                    utf16Column: location.utf16Column,
                    selectsWholeLine: location.selectsWholeLine
                )
                return
            }
            guard let providerID = location.virtualProviderID
                ?? virtualDocumentProviderIDs[location.url]
                ?? languageNavigationState.providerID else {
                showNotification("The virtual source provider is no longer available")
                onFailure?()
                return
            }
            guard let languageToolingSessions = languageToolingSessionsIfActive else {
                showNotification("The language source provider is not running")
                onFailure?()
                return
            }
            let operationID = beginLanguageNavigation(
                providerID: providerID,
                kind: languageNavigationState.kind
            )
            do {
                try languageToolingSessions.resolveVirtualDocument(
                    providerID: providerID,
                    uri: location.url
                ) { [weak self] result in
                    guard let self,
                          self.languageNavigationState.owns(operationID: operationID) else { return }
                    self.languageNavigationState = .idle
                    switch result {
                    case .success(let text):
                        self.virtualDocumentProviderIDs[location.url] = providerID
                        if recordsHistory {
                            self.navigationHistoryFeature.recordJump(from: departure, to: location)
                        }
                        self.documentFeature.openVirtualDocument(
                            location.url,
                            text: text,
                            displayPath: location.displayPath
                        )
                        self.editorNavigationTarget = EditorNavigationTarget(
                            url: location.url,
                            line: location.line,
                            utf16Column: location.utf16Column,
                            selectsWholeLine: location.selectsWholeLine
                        )
                    case .failure(let error):
                        onFailure?()
                        self.showNotification(error.localizedDescription)
                    }
                }
            } catch {
                if languageNavigationState.owns(operationID: operationID) {
                    languageNavigationState = .idle
                }
                onFailure?()
                showNotification(error.localizedDescription)
            }
            return
        }
        if recordsHistory {
            navigationHistoryFeature.recordJump(from: departure, to: location)
        }
        openFile(
            location.url,
            isReadOnly: location.isReadOnly,
            displayPath: location.displayPath
        )
        editorNavigationTarget = EditorNavigationTarget(
            url: location.url.standardizedFileURL,
            line: location.line,
            utf16Column: location.utf16Column,
            selectsWholeLine: location.selectsWholeLine
        )
    }

    private func currentEditorNavigationLocation() -> EditorNavigationLocation? {
        guard let document = activeDocument else { return nil }
        let documentURL = document.url.isFileURL ? document.url.standardizedFileURL : document.url
        let caret = editorCaret.flatMap { caret -> EditorCaret? in
            let caretURL = caret.url.isFileURL ? caret.url.standardizedFileURL : caret.url
            return caretURL == documentURL ? caret : nil
        }
        return EditorNavigationLocation(
            url: documentURL,
            line: caret?.line ?? 0,
            utf16Column: caret?.utf16Column ?? 0,
            isReadOnly: document.isReadOnly,
            displayPath: document.displayPath,
            virtualProviderID: virtualDocumentProviderIDs[documentURL]
        )
    }

    func closeLanguageNavigationResults() {
        isReferencesVisible = false
        isImplementationChooserVisible = false
        clearLanguageNavigationProjection()
    }

    func clearLanguageNavigationProjection() {
        languageNavigationState = .idle
    }

    private func beginLanguageNavigation(
        providerID: String,
        kind: LanguageNavigationResultKind
    ) -> UUID {
        let operationID = UUID()
        languageNavigationState = .loading(
            operationID: operationID,
            providerID: providerID,
            kind: kind
        )
        return operationID
    }

    func requestLanguageHover(
        line: Int,
        utf16Column: Int,
        completion: @escaping (LanguageServerHover?) -> Void
    ) {
        if let document = activeDocument,
           let hover = springFeature.hover(for: document.url, line: line) {
            completion(hover)
            return
        }
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.hover) == true),
              let workspaceURL else {
            completion(nil)
            return
        }
        do {
            try languageToolingSessionsIfActive?.hover(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, line),
                    utf16Column: max(0, utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let hover): completion(hover)
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    completion(nil)
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            completion(nil)
        }
    }

    func requestLanguageCompletions(
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCompletionItem]) -> Void
    ) {
        guard let document = activeDocument else {
            completion([])
            return
        }
        let springCompletions = springFeature.completions(
            document: document,
            line: line,
            utf16Column: utf16Column
        )
        guard
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.completion) == true),
              let workspaceURL else {
            completion(springCompletions)
            return
        }
        do {
            try languageToolingSessionsIfActive?.completions(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, line),
                    utf16Column: max(0, utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let values):
                    var seen = Set<String>()
                    completion((springCompletions + values).filter { seen.insert($0.label).inserted })
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    completion(springCompletions)
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            completion(springCompletions)
        }
    }

    func requestLanguageRename(
        line: Int,
        utf16Column: Int,
        newName: String
    ) {
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.rename) == true),
              let workspaceURL else { return }
        do {
            try languageToolingSessionsIfActive?.rename(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column)),
                newName: newName,
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let edit): self?.applyLanguageWorkspaceEdit(edit)
                case .failure(let error): self?.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageFormatting() {
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.formatting) == true),
              let workspaceURL else { return }
        do {
            try languageToolingSessionsIfActive?.format(
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self, weak document] result in
                guard let self, let document else { return }
                switch result {
                case .success(let edits):
                    self.applyLanguageWorkspaceEdit(
                        LanguageServerWorkspaceEdit(changes: [document.url.standardizedFileURL: edits])
                    )
                case .failure(let error): self.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func requestLanguageCodeActions(
        line: Int,
        utf16Column: Int,
        completion: @escaping ([LanguageServerCodeAction]) -> Void
    ) {
        guard let document = activeDocument,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.codeActions) == true),
              let workspaceURL else { completion([]); return }
        let position = LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column))
        let range = LanguageServerRange(start: position, end: position)
        do {
            try languageToolingSessionsIfActive?.codeActions(
                fileURL: document.url,
                text: document.text,
                range: range,
                diagnostics: languageDiagnostics[document.url.standardizedFileURL] ?? [],
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let actions): completion(actions)
                case .failure(let error): self?.showNotification(error.localizedDescription); completion([])
                }
            }
        } catch { showNotification(error.localizedDescription); completion([]) }
    }

    func applyLanguageCodeAction(_ action: LanguageServerCodeAction) {
        guard let document = activeDocument, let workspaceURL else { return }
        guard action.data != nil,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.codeActionResolve) == true) else {
            performLanguageCodeAction(action, documentURL: document.url, rootURL: workspaceURL)
            return
        }
        do {
            try languageToolingSessionsIfActive?.resolveCodeAction(
                action,
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let resolved):
                    self?.performLanguageCodeAction(resolved, documentURL: document.url, rootURL: workspaceURL)
                case .failure(let error): self?.showNotification(error.localizedDescription)
                }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    private func performLanguageCodeAction(
        _ action: LanguageServerCodeAction,
        documentURL: URL,
        rootURL: URL
    ) {
        if let edit = action.edit, !applyLanguageWorkspaceEdit(edit) { return }
        guard let command = action.command else {
            if action.edit == nil { showNotification("This language action has no executable change.") }
            return
        }
        guard let document = openDocuments.first(where: {
            $0.url.standardizedFileURL == documentURL.standardizedFileURL
        }) else { return }
        do {
            try languageToolingSessionsIfActive?.execute(
                command,
                fileURL: document.url,
                text: document.text,
                rootURL: rootURL
            ) { [weak self] result in
                if case .failure(let error) = result { self?.showNotification(error.localizedDescription) }
            }
        } catch { showNotification(error.localizedDescription) }
    }

    func applyLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange
    ) {
        guard let document = activeDocument, let workspaceURL else { return }
        guard item.data != nil,
              (languageToolingSessionsIfActive?.features(for: document.url).contains(.completionResolve) == true) else {
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
            return
        }
        do {
            try languageToolingSessionsIfActive?.resolveCompletion(
                item,
                fileURL: document.url,
                text: document.text,
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let resolved):
                    self?.performLanguageCompletion(
                        resolved,
                        fallbackRange: fallbackRange,
                        documentURL: document.url
                    )
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    self?.performLanguageCompletion(
                        item,
                        fallbackRange: fallbackRange,
                        documentURL: document.url
                    )
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
        }
    }

    private func performLanguageCompletion(
        _ item: LanguageServerCompletionItem,
        fallbackRange: LanguageServerRange,
        documentURL: URL
    ) {
        let sourceEdit = item.textEdit ?? LanguageServerTextEdit(
            range: fallbackRange,
            newText: item.insertText
        )
        let primaryEdit = LanguageServerTextEdit(
            range: sourceEdit.range,
            newText: LanguageServerSnippet.plainText(sourceEdit.newText)
        )
        let edits = [primaryEdit] + item.additionalTextEdits
        applyLanguageWorkspaceEdit(LanguageServerWorkspaceEdit(
            changes: [documentURL.standardizedFileURL: edits]
        ))
    }

    @discardableResult
    private func applyLanguageWorkspaceEdit(_ edit: LanguageServerWorkspaceEdit) -> Bool {
        guard let workspaceURL else { return false }
        let root = workspaceURL.standardizedFileURL.path
        var sources: [URL: String] = [:]
        var documents: [URL: EditorDocument] = [:]
        do {
            for rawURL in edit.changes.keys {
                let url = rawURL.standardizedFileURL
                guard url.path == root || url.path.hasPrefix(root + "/") else {
                    throw NSError(domain: "LanguageEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Language edit targets a file outside the workspace."])
                }
                if let document = openDocuments.first(where: { $0.url.standardizedFileURL == url }) {
                    guard !document.isReadOnly else { throw EditorDocument.DocumentError.readOnly }
                    documents[url] = document
                    sources[url] = document.text
                } else {
                    guard WorkspaceTextFilePolicy.isReadableTextFile(url) else { throw NSError(domain: "LanguageEdit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Language edit targets an unreadable file."]) }
                    sources[url] = try workspaceFileOperations.readText(from: url)
                }
            }
            var replacements: [URL: String] = [:]
            for (url, edits) in edit.changes {
                let normalized = url.standardizedFileURL
                guard let source = sources[normalized] else { continue }
                replacements[normalized] = try LanguageServerTextEditApplicator.apply(edits, to: source)
            }
            var originals: [URL: String] = [:]
            do {
                // Open documents are editor buffers: mutate them only after
                // every unopened file was written successfully, and leave
                // them dirty instead of silently saving user work.
                for (url, replacement) in replacements where documents[url] == nil {
                    originals[url] = sources[url]
                    try workspaceFileOperations.writeText(replacement, to: url)
                }
            } catch {
                for (url, original) in originals { try? workspaceFileOperations.writeText(original, to: url) }
                throw error
            }
            for (url, replacement) in replacements {
                if let document = documents[url] {
                    document.text = replacement
                    documentDidChange(document)
                }
            }
            return true
        } catch {
            showNotification("Could not apply language edit: \(error.localizedDescription)")
            return false
        }
    }

    func supportsLanguageServerFeature(_ feature: LanguageServerFeatureSet) -> Bool {
        guard let document = activeDocument else { return false }
        return (languageToolingSessionsIfActive?.features(for: document.url).contains(feature) == true)
    }

    private func languageServerFeatureIsReady(
        _ feature: LanguageServerFeatureSet,
        unsupportedMessage: String
    ) -> Bool {
        guard let document = activeDocument else { return false }
        if isJavaLanguageServerPreparing(for: document.url) {
            showJavaLanguageServerPreparingNotification()
            return false
        }
        guard supportsLanguageServerFeature(feature) else {
            showNotification(unsupportedMessage)
            return false
        }
        return true
    }

    private func performGenericNavigation(
        method: String,
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool = true,
        fallbackToImplementationsIfSelf: Bool = false
    ) {
        guard !languageNavigationState.isLoading,
              let document = activeDocument,
              let caret = editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL,
              let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url) else {
            showNotification("Place the caret on a language symbol first")
            return
        }
        let operationID = beginLanguageNavigation(providerID: provider.id, kind: kind)
        do {
            try languageToolingSessionsIfActive?.navigate(
                method: method,
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationState.owns(operationID: operationID) else { return }
                switch result {
                case .failure(let error):
                    self.languageNavigationState = .idle
                    self.showNotification(error.localizedDescription)
                case .success(let values):
                    if fallbackToImplementationsIfSelf,
                       kind == .definitions,
                       values.count == 1,
                       values[0].url.standardizedFileURL == document.url.standardizedFileURL,
                       self.languageToolingSessionsIfActive?.features(for: document.url).contains(.implementation) == true {
                        self.requestGenericImplementationFallback(
                            document: document,
                            caret: caret,
                            workspaceURL: workspaceURL,
                            originalValues: values,
                            navigateToSingleResult: navigateToSingleResult,
                            providerID: provider.id
                        )
                        return
                    }
                    self.presentGenericNavigationValues(
                        values,
                        kind: kind,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: provider.id
                    )
                }
            }
        } catch {
            if languageNavigationState.owns(operationID: operationID) {
                languageNavigationState = .idle
            }
            showNotification(error.localizedDescription)
        }
    }

    private func requestGenericImplementationFallback(
        document: EditorDocument,
        caret: EditorCaret,
        workspaceURL: URL,
        originalValues: [LanguageServerLocation],
        navigateToSingleResult: Bool,
        providerID: String
    ) {
        let operationID = beginLanguageNavigation(
            providerID: providerID,
            kind: .implementations
        )
        do {
            try languageToolingSessionsIfActive?.navigate(
                method: "textDocument/implementation",
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                guard let self,
                      self.languageNavigationState.owns(operationID: operationID) else { return }
                if case .success(let implementations) = result, !implementations.isEmpty {
                    self.presentGenericNavigationValues(
                        implementations,
                        kind: .implementations,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: providerID
                    )
                } else {
                    self.presentGenericNavigationValues(
                        originalValues,
                        kind: .definitions,
                        navigateToSingleResult: navigateToSingleResult,
                        providerID: providerID
                    )
                }
            }
        } catch {
            guard languageNavigationState.owns(operationID: operationID) else { return }
            presentGenericNavigationValues(
                originalValues,
                kind: .definitions,
                navigateToSingleResult: navigateToSingleResult,
                providerID: providerID
            )
        }
    }

    private func presentGenericNavigationValues(
        _ values: [LanguageServerLocation],
        kind: LanguageNavigationResultKind,
        navigateToSingleResult: Bool,
        providerID: String?
    ) {
        let locations = values.map {
            LanguageNavigationLocation(
                url: $0.url,
                line: $0.range.start.line,
                utf16Column: $0.range.start.utf16Column,
                isReadOnly: $0.isReadOnly,
                displayPath: $0.displayPath
            )
        }
        guard !locations.isEmpty else {
            languageNavigationState = .idle
            switch kind {
            case .definitions: showNotification("Definition not found")
            case .references: showNotification("No usages found")
            case .implementations: showNotification("No implementations found")
            }
            return
        }
        languageNavigationState = .results(
            providerID: providerID,
            kind: kind,
            locations: locations
        )
        if navigateToSingleResult, locations.count == 1, let location = locations.first {
            navigate(to: location)
        } else {
            presentLanguageNavigationResults(kind)
        }
    }

    func presentLanguageNavigationResults(_ kind: LanguageNavigationResultKind) {
        isGitLogVisible = false
        isTerminalVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isReferencesVisible = kind != .implementations
        isImplementationChooserVisible = kind == .implementations
    }

}
