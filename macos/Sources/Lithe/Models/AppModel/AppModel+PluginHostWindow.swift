import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// What the plugin host services may read and do in this project window.
///
/// Every method here acts on this window only; nothing raises the window,
/// activates the application, or reads a file's contents. A project window's
/// `id` is the window ID that plugins are given.
@MainActor
extension AppModel: PluginHostWindowPort {
    var hostDocumentService: (any EditorDocumentServicing)? { makeEditorDocumentService() }
    var hostVisibilityRules: FileVisibilityRules { settings.fileVisibilityRules }

    func hostSetHTMLPresentation(at url: URL, previewOnly: Bool) throws {
        guard let document = hostDocument(matching: url) else { throw PluginHostError.documentNotOpen }
        editorTabOrderFeature.documentPreviewModes[document.id] = previewOnly ? .preview : .split
    }
    var hostSnapshot: PluginHostWindowSnapshot? {
        guard let identity = currentWorkspaceIdentity else { return nil }
        return PluginHostWindowSnapshot(
            windowID: id,
            workspaceURL: identity.url,
            workspaceGeneration: identity.generation,
            // The same test the terminal uses to tell a remote workspace's
            // local placeholder root from a local folder.
            isRemoteWorkspace: services.remoteConnections?.workspaces.contains(identity.url) == true,
            isForeground: workspaceSessionCoordinator.isActive,
            roots: [PluginHostRoot(id: PluginHostResource.workspaceRootID, url: identity.url)]
        )
    }

    var hostMessages: PluginHostMessageFeatureModel { featureGraph.pluginMessages }

    func hostDocumentState(at url: URL, flushingEditor: Bool) async -> PluginHostDocumentState? {
        guard currentWorkspaceIdentity != nil else { return nil }
        let normalized = url.standardizedFileURL
        guard let document = hostDocument(matching: normalized) else {
            return PluginHostDocumentState(
                url: normalized, isOpen: false, hasUnsavedChanges: false, isActive: false, isReadOnly: false
            )
        }
        var editorConfirmed = true
        if flushingEditor { editorConfirmed = await hostFlushEditor(of: document) }
        // The window or the tab may have gone while the editor was answering.
        guard currentWorkspaceIdentity != nil, openDocuments.contains(where: { $0 === document }) else { return nil }
        return PluginHostDocumentState(
            documentID: document.id, version: document.contentVersion,
            url: normalized,
            isOpen: true,
            // A buffer whose latest input the editor did not confirm may be
            // newer than the model knows, so it counts as unsaved.
            hasUnsavedChanges: document.isDirty || !editorConfirmed,
            isActive: hostIsForegroundTab(document),
            isReadOnly: document.isReadOnly
        )
    }

    func hostOpenDocument(at url: URL, activation: PluginHostEditorActivation) async -> PluginHostDocumentState? {
        guard let identity = currentWorkspaceIdentity else { return nil }
        let normalized = url.standardizedFileURL
        // Images and other media open in their own viewer, which has no text
        // buffer to report; the caller is told the file cannot be opened.
        guard MediaDocumentKind.from(url: normalized) == nil else { return nil }
        if activation == .select {
            // The same preparation as opening a file from the project tree.
            suggestJavaPluginIfNeeded(files: [normalized])
            editorTabOrderFeature.repositoryDiffSelected = false
            editorNavigationTarget = nil
        }
        // An open buffer is only activated, never reloaded, so unsaved edits stay.
        await documentFeature.openFileAsync(
            normalized, isReadOnly: false, displayPath: nil, activateWhenReady: activation == .select
        )
        guard currentWorkspaceIdentity == identity,
              let document = hostDocument(matching: normalized) else { return nil }
        if activation == .select {
            // Selecting the tab like a click does puts it in front across
            // editor groups and over a diff, terminal or Agent tab.
            selectEditorTab(.document(document.id))
        }
        return PluginHostDocumentState(
            documentID: document.id, version: document.contentVersion,
            url: normalized,
            isOpen: true,
            hasUnsavedChanges: document.isDirty,
            isActive: hostIsForegroundTab(document),
            isReadOnly: document.isReadOnly
        )
    }

    func hostPlaceCaret(in url: URL, at position: PluginHostPosition) {
        guard currentWorkspaceIdentity != nil else { return }
        // Plugin positions start at 1; the editor's navigation target starts at 0.
        editorNavigationTarget = EditorNavigationTarget(
            url: url.standardizedFileURL,
            line: max(0, position.line - 1),
            utf16Column: max(0, position.column - 1)
        )
    }

    func hostNoteMessageLimit(pluginName: String) {
        showNotification("%@ sent messages too quickly, so some were not shown.", arguments: [pluginName])
    }

    /// Ends the plugin messages of this window, for a closing window or a replaced workspace.
    func dismissPluginHostMessages(_ reason: PluginHostMessageDismissal) {
        featureGraph.pluginMessages.dismissAll(reason)
    }

    private func hostDocument(matching url: URL) -> EditorDocument? {
        let path = url.standardizedFileURL.path
        return openDocuments.first { $0.url.standardizedFileURL.path == path }
    }

    /// True when the file's tab is the one in front: selected in the focused
    /// editor group, with no diff tab over it.
    func hostIsForegroundTab(_ document: EditorDocument) -> Bool {
        guard activeDocumentID == document.id, !editorTabOrderFeature.repositoryDiffSelected else { return false }
        // Before the editor area first mounts nothing is focused yet; the
        // active document then is the foreground one.
        guard let focused = editorTabOrderFeature.focusedItem else { return true }
        return focused == .document(document.id)
    }

    /// True when the editor confirmed it handed over all input; false on failure or timeout.
    private func hostFlushEditor(of document: EditorDocument) async -> Bool {
        guard document.needsEditorSynchronization else { return true }
        return await PluginHostEditorFlush.run { done in
            document.withSynchronizedEditor { result in
                if case .success = result { done(true) } else { done(false) }
            }
        }
    }
}
