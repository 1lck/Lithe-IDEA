import Foundation

@MainActor
extension AppModel {
    func navigateBack() {
        let current = editorCaret.map {
            EditorNavigationTarget(url: $0.url, line: $0.line, utf16Column: $0.utf16Column)
        }
        guard let destination = editorNavigationFeature.takeBackDestination(from: current) else { return }
        navigateEditor(to: destination, recordsHistory: false)
    }

    func navigateForward() {
        let current = editorCaret.map {
            EditorNavigationTarget(url: $0.url, line: $0.line, utf16Column: $0.utf16Column)
        }
        guard let destination = editorNavigationFeature.takeForwardDestination(from: current) else { return }
        navigateEditor(to: destination, recordsHistory: false)
    }

    func toggleRun() {
        isRunVisible.toggle()
        guard isRunVisible else { return }
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
            if self.mavenFeature.project == nil {
                await self.loadProjectServices(at: workspaceURL, files: self.projectFiles)
            }
        }
    }

    func runMaven(
        phase: MavenLifecyclePhase,
        module: MavenModule?,
        profiles: Set<String>
    ) {
        isMavenVisible = true
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isRunVisible = false
        isDebugVisible = false
        mavenFeature.run(phase: phase, module: module, profiles: profiles)
    }

    func stopMaven() {
        mavenFeature.stop()
    }

    func openMavenIssue(_ issue: MavenBuildIssue) {
        guard let fileURL = issue.fileURL,
              workspaceFeature.fileExists(at: fileURL) else { return }
        navigateEditor(to: EditorNavigationTarget(
            url: fileURL.standardizedFileURL,
            line: max(0, (issue.line ?? 1) - 1),
            utf16Column: max(0, (issue.column ?? 1) - 1)
        ))
    }

    /// 打开源码文件并定位到指定行/列(供构建输出、运行堆栈等可点击文本跳转)。
    func openSourceLocation(url: URL, line: Int, column: Int?) {
        guard workspaceFeature.fileExists(at: url) else { return }
        navigateEditor(to: EditorNavigationTarget(
            url: url.standardizedFileURL,
            line: max(0, line - 1),
            utf16Column: max(0, (column ?? 1) - 1)
        ))
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
        navigateEditor(to: EditorNavigationTarget(
            url: diagnostic.fileURL.standardizedFileURL,
            line: diagnostic.line,
            utf16Column: diagnostic.utf16Column
        ))
    }

    func selectRunConfiguration(_ configuration: RunConfiguration) {
        runFeature.select(configuration)
    }

    func openRunConfiguration(relativePath: String?) {
        guard let workspaceURL else { return }
        let url = workspaceURL.appendingPathComponent(relativePath ?? ".lithe/run/generated.json")
        guard workspaceFeature.fileExists(at: url) else { return }
        openFile(url)
    }

    func runSelectedConfiguration() {
        guard runFeature.configurationStatus == .ready else {
            runFeature.requestRunConfigurationGeneration(intent: .run)
            return
        }
        guard let configuration = runFeature.selectedConfiguration else { return }
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
        runFeature.restart()
    }

    func stopSelectedRun() {
        runFeature.stop()
    }

    func toggleDebug() {
        isDebugVisible.toggle()
        guard isDebugVisible else { return }
        isTestsVisible = false
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
    }

    func startDebugging() {
        if let document = activeDocument,
           languageToolingSessions.supportsGenericDebugging(for: document.url) {
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
        isGitLogVisible = false
        isTerminalVisible = false
        isReferencesVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isDebugVisible = false
        if let workspaceURL {
            languageTestService.discover(workspaceURL: workspaceURL, files: projectFiles)
        }
    }

    func refreshTests() {
        guard let workspaceURL else { return }
        languageTestService.discover(workspaceURL: workspaceURL, files: projectFiles)
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
        _ = languageTestService.run(
            providerID: providerID,
            scope: scope,
            workspaceURL: workspaceURL,
            projectFiles: projectFiles
        )
    }

    func stopTests() {
        languageTestService.stop()
    }

    func stopDebugging() {
        if genericDebugFeature.providerID != nil {
            genericDebugFeature.stop()
        } else {
            debugFeature.stop()
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
        if languageToolingSessions.supportsGenericDebugging(for: fileURL) {
            genericDebugFeature.toggleBreakpoint(fileURL: fileURL, line: line)
        } else if javaFeature.supportsLegacyDebugging(fileURL: fileURL) {
            javaFeature.toggleDebugBreakpoint(at: fileURL, line: line, documents: openDocuments)
        } else {
            showNotification("Debugging is not supported for this file type")
        }
    }

    var prefersGenericDebugUI: Bool {
        if genericDebugFeature.providerID != nil { return true }
        guard let document = activeDocument else { return false }
        // Never show the Java/JDB panel for another language. A configured
        // Provider may still be unavailable locally; the generic panel can
        // then present the Provider's installation error without leaking a
        // Java-specific workflow into that project.
        guard let descriptor = languageProviderCatalog.provider(for: document.url) else {
            return true
        }
        return descriptor.id != "java"
            || languageToolingSessions.supportsGenericDebugging(for: document.url)
    }

    private func startGenericDebugging(_ document: EditorDocument) {
        guard let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url) else {
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

    func goToDefinition(line: Int? = nil, utf16Column: Int? = nil) {
        guard supportsLanguageServerFeature(.definition) else {
            showNotification("Definition navigation is not supported by this language server")
            return
        }
        performGenericNavigation(
            method: "textDocument/definition",
            kind: .definitions,
            caretOverride: navigationCaret(line: line, utf16Column: utf16Column)
        )
    }

    func goToUsages() {
        guard supportsLanguageServerFeature(.references) else {
            showNotification("Reference navigation is not supported by this language server")
            return
        }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            presentation: .chooser
        )
    }

    func goToDeclarationOrUsages(line: Int? = nil, utf16Column: Int? = nil) {
        guard supportsLanguageServerFeature(.definition) else {
            if supportsLanguageServerFeature(.references) {
                goToUsages()
            } else {
                showNotification("Navigation is not supported by this language server")
            }
            return
        }
        guard let document = activeDocument,
              let caret = navigationCaret(line: line, utf16Column: utf16Column) ?? editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL,
              let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url) else {
            showNotification("Place the caret on a language symbol first")
            return
        }

        isLoadingLanguageNavigation = true
        languageNavigationSubject = navigationSubject(in: document, at: caret)
        languageNavigationProviderID = provider.id
        languageNavigationResultKind = .definitions
        let requestID = UUID()
        languageNavigationRequestID = requestID
        flushLanguageServerSynchronization(for: document)
        do {
            try languageToolingSessions.navigate(
                method: "textDocument/definition",
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL,
                waitingForLanguageServer: { [weak self] in
                    guard let self, self.languageNavigationRequestID == requestID else { return }
                    self.showNotification("Language server is warming up or indexing. Navigation will continue when it is ready.")
                }
            ) { [weak self] result in
                guard let self, self.languageNavigationRequestID == requestID else { return }
                switch result {
                case .failure(let error):
                    self.isLoadingLanguageNavigation = false
                    self.languageNavigationProviderID = nil
                    self.showNotification(error.localizedDescription)
                case .success(let definitions):
                    let isAtDeclaration = definitions.count == 1
                        && definitions.first.map { LanguageNavigationSemantics.contains(caret, in: $0) } == true
                    if isAtDeclaration,
                       self.languageToolingSessions.features(for: document.url).contains(.references) {
                        self.requestUsagesForDeclaration(
                            document: document,
                            caret: caret,
                            workspaceURL: workspaceURL,
                            requestID: requestID
                        )
                    } else {
                        self.isLoadingLanguageNavigation = false
                        self.presentGenericNavigationValues(
                            definitions,
                            kind: .definitions,
                            presentation: .navigateSingle
                        )
                    }
                }
            }
        } catch {
            isLoadingLanguageNavigation = false
            languageNavigationProviderID = nil
            showNotification(error.localizedDescription)
        }
    }

    func goToImplementation(line: Int? = nil, utf16Column: Int? = nil) {
        guard supportsLanguageServerFeature(.implementation) else {
            showNotification("Implementation navigation is not supported by this language server")
            return
        }
        performGenericNavigation(
            method: "textDocument/implementation",
            kind: .implementations,
            caretOverride: navigationCaret(line: line, utf16Column: utf16Column)
        )
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
        if languageToolingSessions.features(for: normalizedURL).contains(.definition) {
            performGenericNavigation(
                method: "textDocument/definition",
                kind: .definitions,
                fallbackToImplementationsIfSelf: true
            )
        }
    }

    func findReferences(line: Int? = nil, utf16Column: Int? = nil) {
        guard supportsLanguageServerFeature(.references) else {
            showNotification("Reference navigation is not supported by this language server")
            return
        }
        performGenericNavigation(
            method: "textDocument/references",
            kind: .references,
            presentation: .toolWindow,
            caretOverride: navigationCaret(line: line, utf16Column: utf16Column)
        )
    }

    func findJavaImplementations(line: Int, utf16Column: Int, in fileURL: URL) {
        editorCaret = EditorCaret(
            url: fileURL.standardizedFileURL,
            line: line,
            utf16Column: utf16Column
        )
        guard supportsLanguageServerFeature(.implementation) else {
            showNotification("Implementation navigation is not supported by this language server")
            return
        }
        performGenericNavigation(
            method: "textDocument/implementation",
            kind: .implementations,
            presentation: .chooser
        )
    }

    func navigate(to location: LanguageNavigationLocation) {
        languageNavigationRequestID = UUID()
        isLoadingLanguageNavigation = false
        isLanguageNavigationChooserVisible = false
        guard location.url.isFileURL else {
            guard let providerID = languageNavigationProviderID else {
                showNotification("The virtual source provider is no longer available")
                return
            }
            isLoadingLanguageNavigation = true
            do {
                try languageToolingSessions.resolveVirtualDocument(
                    providerID: providerID,
                    uri: location.url
                ) { [weak self] result in
                    guard let self else { return }
                    self.isLoadingLanguageNavigation = false
                    switch result {
                    case .success(let text):
                        self.documentFeature.openVirtualDocument(
                            location.url,
                            text: text,
                            displayPath: location.displayPath
                        )
                        self.editorNavigationFeature.reveal(EditorNavigationTarget(
                            url: location.url,
                            range: location.range
                        ))
                    case .failure(let error):
                        self.showNotification(error.localizedDescription)
                    }
                }
            } catch {
                isLoadingLanguageNavigation = false
                showNotification(error.localizedDescription)
            }
            return
        }
        navigateEditor(
            to: EditorNavigationTarget(
                url: location.url.standardizedFileURL,
                range: location.range
            ),
            isReadOnly: location.isReadOnly,
            displayPath: location.displayPath
        )
    }

    func closeLanguageNavigationResults() {
        isReferencesVisible = false
        isLanguageNavigationChooserVisible = false
        clearLanguageNavigationProjection()
    }

    func clearLanguageNavigationProjection() {
        languageNavigationRequestID = UUID()
        languageNavigationProviderID = nil
        languageNavigationLocations = []
        languageNavigationPreviews = [:]
        languageNavigationSubject = ""
        languageNavigationPreviewRequestID = UUID()
        isLoadingLanguageNavigation = false
    }

    func requestLanguageHover(
        line: Int,
        utf16Column: Int,
        completion: @escaping (LanguageServerHover?) -> Void
    ) {
        guard let document = activeDocument,
              languageToolingSessions.features(for: document.url).contains(.hover),
              let workspaceURL else {
            completion(nil)
            return
        }
        do {
            try languageToolingSessions.hover(
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
        guard let document = activeDocument,
              languageToolingSessions.features(for: document.url).contains(.completion),
              let workspaceURL else {
            completion([])
            return
        }
        do {
            try languageToolingSessions.completions(
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, line),
                    utf16Column: max(0, utf16Column)
                ),
                rootURL: workspaceURL
            ) { [weak self] result in
                switch result {
                case .success(let values): completion(values)
                case .failure(let error):
                    self?.showNotification(error.localizedDescription)
                    completion([])
                }
            }
        } catch {
            showNotification(error.localizedDescription)
            completion([])
        }
    }

    func requestLanguageRename(
        line: Int,
        utf16Column: Int,
        newName: String
    ) {
        guard let document = activeDocument,
              languageToolingSessions.features(for: document.url).contains(.rename),
              let workspaceURL else { return }
        do {
            try languageToolingSessions.rename(
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
              languageToolingSessions.features(for: document.url).contains(.formatting),
              let workspaceURL else { return }
        do {
            try languageToolingSessions.format(
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
              languageToolingSessions.features(for: document.url).contains(.codeActions),
              let workspaceURL else { completion([]); return }
        let position = LanguageServerPosition(line: max(0, line), utf16Column: max(0, utf16Column))
        let range = LanguageServerRange(start: position, end: position)
        do {
            try languageToolingSessions.codeActions(
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
              languageToolingSessions.features(for: document.url).contains(.codeActionResolve) else {
            performLanguageCodeAction(action, documentURL: document.url, rootURL: workspaceURL)
            return
        }
        do {
            try languageToolingSessions.resolveCodeAction(
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
            try languageToolingSessions.execute(
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
              languageToolingSessions.features(for: document.url).contains(.completionResolve) else {
            performLanguageCompletion(item, fallbackRange: fallbackRange, documentURL: document.url)
            return
        }
        do {
            try languageToolingSessions.resolveCompletion(
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
        return languageToolingSessions.features(for: document.url).contains(feature)
    }

    private func performGenericNavigation(
        method: String,
        kind: LanguageNavigationResultKind,
        presentation: LanguageNavigationPresentation = .navigateSingle,
        fallbackToImplementationsIfSelf: Bool = false,
        caretOverride: EditorCaret? = nil
    ) {
        guard let document = activeDocument,
              let caret = caretOverride ?? editorCaret,
              caret.url.standardizedFileURL == document.url.standardizedFileURL,
              let workspaceURL,
              let provider = languageProviderCatalog.provider(for: document.url) else {
            showNotification("Place the caret on a language symbol first")
            return
        }
        isLoadingLanguageNavigation = true
        if presentation == .chooser {
            isLanguageNavigationChooserVisible = true
            languageNavigationLocations = []
            languageNavigationPreviews = [:]
        }
        languageNavigationSubject = navigationSubject(in: document, at: caret)
        languageNavigationProviderID = provider.id
        languageNavigationResultKind = kind
        let requestID = UUID()
        languageNavigationRequestID = requestID
        flushLanguageServerSynchronization(for: document)
        do {
            try languageToolingSessions.navigate(
                method: method,
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL,
                provisional: { [weak self] values in
                    guard let self, self.languageNavigationRequestID == requestID else { return }
                    // A direct definition/implementation jump must stay visually
                    // stable; lexical candidates are only useful in result lists.
                    if case .navigateSingle = presentation { return }
                    self.presentProvisionalGenericNavigationValues(
                        values,
                        kind: kind,
                        presentation: presentation
                    )
                },
                waitingForLanguageServer: { [weak self] in
                    guard let self, self.languageNavigationRequestID == requestID else { return }
                    self.showNotification("Language server is warming up or indexing. Navigation will continue when it is ready.")
                }
            ) { [weak self] result in
                guard let self, self.languageNavigationRequestID == requestID else { return }
                self.isLoadingLanguageNavigation = false
                switch result {
                case .failure(let error):
                    self.languageNavigationProviderID = nil
                    if presentation == .chooser {
                        self.isLanguageNavigationChooserVisible = false
                    }
                    self.showNotification(error.localizedDescription)
                case .success(let values):
                    if fallbackToImplementationsIfSelf,
                       kind == .definitions,
                       values.count == 1,
                       values[0].url.standardizedFileURL == document.url.standardizedFileURL,
                       self.languageToolingSessions.features(for: document.url).contains(.implementation) {
                        self.requestGenericImplementationFallback(
                            document: document,
                            caret: caret,
                            workspaceURL: workspaceURL,
                            originalValues: values,
                            presentation: presentation,
                            requestID: requestID
                        )
                        return
                    }
                    self.presentGenericNavigationValues(
                        values,
                        kind: kind,
                        presentation: presentation
                    )
                }
            }
        } catch {
            isLoadingLanguageNavigation = false
            languageNavigationProviderID = nil
            if presentation == .chooser {
                isLanguageNavigationChooserVisible = false
            }
            showNotification(error.localizedDescription)
        }
    }

    private func requestUsagesForDeclaration(
        document: EditorDocument,
        caret: EditorCaret,
        workspaceURL: URL,
        requestID: UUID
    ) {
        languageNavigationResultKind = .references
        isLanguageNavigationChooserVisible = true
        languageNavigationLocations = []
        languageNavigationPreviews = [:]
        do {
            try languageToolingSessions.navigate(
                method: "textDocument/references",
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL,
                provisional: { [weak self] values in
                    guard let self, self.languageNavigationRequestID == requestID else { return }
                    self.presentProvisionalGenericNavigationValues(
                        values,
                        kind: .references,
                        presentation: .chooser
                    )
                },
                waitingForLanguageServer: { [weak self] in
                    guard let self, self.languageNavigationRequestID == requestID else { return }
                    self.showNotification("Language server is warming up or indexing. Navigation will continue when it is ready.")
                }
            ) { [weak self] result in
                guard let self, self.languageNavigationRequestID == requestID else { return }
                self.isLoadingLanguageNavigation = false
                switch result {
                case .failure(let error):
                    self.languageNavigationProviderID = nil
                    self.isLanguageNavigationChooserVisible = false
                    self.showNotification(error.localizedDescription)
                case .success(let values):
                    self.presentGenericNavigationValues(
                        values,
                        kind: .references,
                        presentation: .chooser
                    )
                }
            }
        } catch {
            isLoadingLanguageNavigation = false
            languageNavigationProviderID = nil
            isLanguageNavigationChooserVisible = false
            showNotification(error.localizedDescription)
        }
    }

    private func navigationCaret(line: Int?, utf16Column: Int?) -> EditorCaret? {
        guard let document = activeDocument,
              let line,
              let utf16Column else { return nil }
        return EditorCaret(
            url: document.url.standardizedFileURL,
            line: max(0, line),
            utf16Column: max(0, utf16Column)
        )
    }

    private func navigationSubject(in document: EditorDocument, at caret: EditorCaret) -> String {
        let selected = editorSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return ProjectSymbolNavigation.identifier(
            in: document.text,
            at: LanguageServerPosition(line: caret.line, utf16Column: caret.utf16Column)
        )?.value ?? ""
    }

    private func requestGenericImplementationFallback(
        document: EditorDocument,
        caret: EditorCaret,
        workspaceURL: URL,
        originalValues: [LanguageServerLocation],
        presentation: LanguageNavigationPresentation,
        requestID: UUID
    ) {
        isLoadingLanguageNavigation = true
        do {
            try languageToolingSessions.navigate(
                method: "textDocument/implementation",
                fileURL: document.url,
                text: document.text,
                position: LanguageServerPosition(
                    line: max(0, caret.line),
                    utf16Column: max(0, caret.utf16Column)
                ),
                rootURL: workspaceURL,
                waitingForLanguageServer: { [weak self] in
                    guard let self, self.languageNavigationRequestID == requestID else { return }
                    self.showNotification("Language server is warming up or indexing. Navigation will continue when it is ready.")
                }
            ) { [weak self] result in
                guard let self, self.languageNavigationRequestID == requestID else { return }
                self.isLoadingLanguageNavigation = false
                if case .success(let implementations) = result, !implementations.isEmpty {
                    self.presentGenericNavigationValues(
                        implementations,
                        kind: .implementations,
                        presentation: presentation
                    )
                } else {
                    self.presentGenericNavigationValues(
                        originalValues,
                        kind: .definitions,
                        presentation: presentation
                    )
                }
            }
        } catch {
            isLoadingLanguageNavigation = false
            presentGenericNavigationValues(
                originalValues,
                kind: .definitions,
                presentation: presentation
            )
        }
    }

    private func presentGenericNavigationValues(
        _ values: [LanguageServerLocation],
        kind: LanguageNavigationResultKind,
        presentation: LanguageNavigationPresentation
    ) {
        let locations = values.map {
            LanguageNavigationLocation(
                url: $0.url,
                range: $0.range,
                isReadOnly: $0.isReadOnly,
                displayPath: $0.displayPath
            )
        }
        languageNavigationResultKind = kind
        languageNavigationLocations = locations
        loadLanguageNavigationPreviews(for: locations)
        guard !locations.isEmpty else {
            isLanguageNavigationChooserVisible = false
            switch kind {
            case .definitions: showNotification("Definition not found")
            case .references: showNotification("No usages found")
            case .implementations: showNotification("No implementations found")
            }
            return
        }
        if presentation == .navigateSingle, locations.count == 1, let location = locations.first {
            navigate(to: location)
        } else {
            presentLanguageNavigationResults(
                kind,
                presentation: presentation == .navigateSingle ? .chooser : presentation
            )
        }
    }

    private func presentProvisionalGenericNavigationValues(
        _ values: [LanguageServerLocation],
        kind: LanguageNavigationResultKind,
        presentation: LanguageNavigationPresentation
    ) {
        guard !values.isEmpty else { return }
        let locations = values.map {
            LanguageNavigationLocation(
                url: $0.url,
                range: $0.range,
                isReadOnly: $0.isReadOnly,
                displayPath: $0.displayPath
            )
        }
        languageNavigationResultKind = kind
        languageNavigationLocations = locations
        loadLanguageNavigationPreviews(for: locations)
        // Lexical index results are intentionally never auto-jumped. The LSP
        // may replace them with the semantic destination a moment later.
        presentLanguageNavigationResults(
            kind,
            presentation: presentation == .toolWindow ? .toolWindow : .chooser
        )
    }

    private func loadLanguageNavigationPreviews(for locations: [LanguageNavigationLocation]) {
        let requestID = UUID()
        languageNavigationPreviewRequestID = requestID
        languageNavigationPreviews = [:]
        let openSources = Dictionary(uniqueKeysWithValues: openDocuments.map {
            ($0.url.standardizedFileURL, $0.text)
        })
        let operations = workspaceFileOperations

        Task { [weak self] in
            let previews = await Task.detached(priority: .userInitiated) {
                LanguageNavigationPreview.build(
                    locations: locations,
                    openSources: openSources,
                    readSource: { try? operations.readText(from: $0) }
                )
            }.value
            guard let self, self.languageNavigationPreviewRequestID == requestID else { return }
            self.languageNavigationPreviews = previews
        }
    }

    private func presentLanguageNavigationResults(
        _ kind: LanguageNavigationResultKind,
        presentation: LanguageNavigationPresentation = .toolWindow
    ) {
        isGitLogVisible = false
        isTerminalVisible = false
        isProblemsVisible = false
        isMavenVisible = false
        isRunVisible = false
        isReferencesVisible = presentation == .toolWindow
        isLanguageNavigationChooserVisible = presentation == .chooser
    }

}

private enum LanguageNavigationPresentation {
    case navigateSingle
    case chooser
    case toolWindow
}
