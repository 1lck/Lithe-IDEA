import LitheDatabaseModule
import Foundation
import LitheCoreContracts
import LitheGitModule
import LitheLocalHistoryModule
import LitheSearchModule

extension AppModel {
    var workspaceSnapshotID: UUID? { workspaceFeature.appliedSnapshot?.id }
    var springEndpoints: [SpringEndpoint] { springFeature.endpoints }
    var springBeans: [SpringBean] { springFeature.beans }
    var isIndexingSpring: Bool { springFeature.isIndexing }
    var rootNode: FileNode? { workspaceFeature.rootNode }
    var projectFiles: [URL] { workspaceFeature.projectFiles }
    var projectDirectoryMarks: [String: WorkspaceDirectoryMark] {
        workspaceFeature.directoryMarks
    }
    var javaEnvironmentReport: JavaEnvironmentReport? {
        runtimeFeature.javaEnvironmentReport
    }

    var shouldShowJavaEnvironmentBanner: Bool {
        guard javaEnvironmentReport?.status.requiresAttention == true else { return false }
        return projectFiles.contains { $0.pathExtension.lowercased() == "java" }
            || hasMavenProject
            || activeDocument?.url.pathExtension.lowercased() == "java"
    }

    /// A Maven project counts as Java for the Java environment banner. Build
    /// tool windows come from build-system plugins, not from this check.
    var hasMavenProject: Bool {
        projectFiles.contains { $0.lastPathComponent.lowercased() == "pom.xml" }
    }

    var openDocuments: [EditorDocument] { documentFeature.openDocuments }
    var openMediaDocuments: [MediaDocument] { mediaFeature.openMediaDocuments }
    var activeMediaDocument: MediaDocument? { mediaFeature.activeMediaDocument }
    var standaloneFileLoadState: StandaloneFileLoadState {
        documentFeature.standaloneFileLoadState
    }
    var pendingEncodingReopen: DocumentFeatureModel.EncodingReopenRequest? {
        documentFeature.pendingEncodingReopen
    }
    var projectTreeRevealRequest: ProjectTreeRevealRequest? {
        documentFeature.projectTreeRevealRequest
    }

    func canRevealInProjectTree(_ url: URL) -> Bool {
        projectTreeURL(for: url) != nil
    }

    func projectTreeURL(for url: URL) -> URL? {
        workspaceFeature.projectTreeURL(for: url)
    }

    /// Lists expanded project directories that have not been loaded yet.
    func loadExpandedProjectDirectories(_ expandedPaths: Set<String>) async {
        await workspaceFeature.loadExpandedDirectories(expandedPaths)
    }

    func revealInProjectTree(_ url: URL, isDirectory: Bool = false) {
        guard let treeURL = projectTreeURL(for: url) else {
            showNotification("This file is not in the current workspace")
            return
        }
        selectedSidebar = .project
        documentFeature.requestProjectTreeReveal(for: treeURL, isDirectory: isDirectory)
    }

    func consumeProjectTreeRevealRequest(id: UUID) {
        documentFeature.consumeProjectTreeRevealRequest(id: id)
    }

    var activeMediaDocumentID: UUID? { mediaFeature.activeMediaDocumentID }

    var activeDocumentID: UUID? {
        get { documentFeature.activeDocumentID }
        set {
            if newValue != nil {
                editorTabOrderFeature.repositoryDiffSelected = false
                editorTabOrderFeature.databaseSelected = false
            }
            let previousDocumentID = documentFeature.activeDocumentID
            documentFeature.activeDocumentID = newValue
            if let newValue { editorTabOrderFeature.focus(.document(newValue)) }
            guard previousDocumentID != newValue else { return }
            activateCurrentDocumentLanguageServerIfAvailable()
        }
    }

    var isRepositoryDiffSelected: Bool {
        // These surfaces take precedence over the editor tabs in EditorAreaView.
        !isDatabaseWorkspaceSelected && selectedChange == nil && branchComparison == nil
            && editorTabOrderFeature.contains(.repositoryDiff) && (editorTabOrderFeature.repositoryDiffSelected
            || activeDocument == nil && activeEditorTerminalSession == nil && activeMediaDocument == nil)
    }
    var editorTabItems: [EditorTabItem] {
        editorTabOrderFeature.items.filter { item in
            switch item {
            case .database(let profileID?):
                return databaseFeatureIfActive?.profiles.contains(where: { $0.id == profileID }) == true
            case let .databaseQuery(profileID, queryID):
                return databaseFeatureIfActive?.sqlTab(queryID, profileID: profileID) != nil
            default: return true
            }
        }
    }

    var activeDatabaseEditorTab: EditorTabItem {
        if editorTabOrderFeature.databaseOverviewSelected { return .databaseOverview }
        if let queryID = editorTabOrderFeature.databaseQuerySelected, let profileID = editorTabOrderFeature.databaseProfileSelected {
            return .databaseQuery(profileID: profileID, queryID: queryID)
        }
        return .database(editorTabOrderFeature.databaseProfileSelected)
    }

    var isDatabaseWorkspaceSelected: Bool {
        editorTabOrderFeature.databaseSelected && editorTabOrderFeature.contains(activeDatabaseEditorTab)
            && databaseFeatureIfActive != nil && selectedChange == nil && branchComparison == nil
    }

    func openDatabaseWorkspace(overview: Bool = false, queryID: UUID? = nil) {
        guard let feature = databaseFeatureIfActive else { return }
        let item: EditorTabItem
        if let queryID {
            guard let profileID = feature.selectedProfileID, feature.sqlTab(queryID, profileID: profileID) != nil else { return }
            item = .databaseQuery(profileID: profileID, queryID: queryID)
            feature.selectedSQLTabID = queryID
        } else {
            item = overview ? .databaseOverview : .database(feature.selectedProfileID)
        }
        editorTabOrderFeature.databaseProfileSelected = feature.selectedProfileID
        editorTabOrderFeature.databaseQuerySelected = queryID
        if queryID != nil { feature.workspaceSection = .sql }
        else if !overview && feature.workspaceSection == .sql { feature.workspaceSection = .data }
        if !editorTabOrderFeature.contains(item) { editorTabOrderFeature.moveToEnd(item) }
        editorTabOrderFeature.databaseOverviewSelected = overview
        selectedChange = nil
        closeBranchComparison()
        editorTabOrderFeature.repositoryDiffSelected = false
        editorTabOrderFeature.databaseSelected = true
        editorTabOrderFeature.focus(item)
    }

    func selectDatabaseWorkspace(profileID: UUID?, refresh: Bool = false, table: String? = nil, queryID: UUID? = nil) {
        guard let feature = databaseFeatureIfActive else { return }
        if let profileID, let profile = feature.profiles.first(where: { $0.id == profileID }) {
            let needsRefresh = refresh || feature.selectedProfileID != profileID
            if feature.selectedProfileID != profileID { feature.activateProfile(profile) }
            if let table { feature.selectTable(table) }
            // Navigation belongs to the click, not the completion of database I/O.
            openDatabaseWorkspace(queryID: queryID)
            if (needsRefresh || table != nil), profile.kind.supportsDataGrid {
                Task {
                    guard databaseFeatureIfActive === feature, feature.selectedProfileID == profileID else { return }
                    if needsRefresh {
                        await feature.refreshTables()
                    } else if let table, feature.selectedTable == table {
                        await feature.openTable(table)
                    }
                }
            }
        } else if profileID == nil {
            if feature.selectedProfileID != nil { feature.showGlobalHistory() }
            openDatabaseWorkspace()
        }
    }

    func openDatabaseQuery(profileID: UUID, sql: String = "") {
        guard let feature = databaseFeatureIfActive,
              let profile = feature.profiles.first(where: { $0.id == profileID }), profile.kind.isSQLDatabase else { return }
        let switchedProfile = feature.selectedProfileID != profileID
        if switchedProfile { feature.activateProfile(profile) }
        if let tab = feature.selectedSQLTab, tab.sql.isEmpty, !tab.isRunning,
           !editorTabOrderFeature.contains(.databaseQuery(profileID: profileID, queryID: tab.id)) {
            feature.updateSQL(sql, in: tab.id)
        } else {
            feature.addSQLTab(sql: sql)
        }
        selectDatabaseWorkspace(profileID: profileID, refresh: switchedProfile, queryID: feature.selectedSQLTabID)
    }

    func removeDatabaseConnection(_ profile: DatabaseProfile) {
        guard let feature = databaseFeatureIfActive, feature.remove(profile) else { return }
        // Remove background tabs first, so fallback cannot reopen another deleted console.
        let removed = editorTabOrderFeature.items.filter {
            switch $0 {
            case .database(let id): return id == profile.id
            case .databaseQuery(let id, _): return id == profile.id
            default: return false
            }
        }
        for item in removed where item != activeDatabaseEditorTab { closeDatabaseTab(item) }
        if removed.contains(activeDatabaseEditorTab) { closeDatabaseTab(activeDatabaseEditorTab) }
    }

    func closeDatabaseTab(_ item: EditorTabItem) {
        let wasSelected = isDatabaseWorkspaceSelected && activeDatabaseEditorTab == item
        editorTabOrderFeature.remove(item)
        if case let .databaseQuery(profileID, queryID) = item {
            databaseFeatureIfActive?.closeSQLTab(queryID, profileID: profileID)
        }
        guard wasSelected else { return }
        editorTabOrderFeature.databaseSelected = false
        editorTabOrderFeature.databaseProfileSelected = nil
        editorTabOrderFeature.databaseQuerySelected = nil
        editorTabOrderFeature.databaseOverviewSelected = false
        if let next = editorTabItems.last(where: {
            switch $0 {
            case .database, .databaseQuery, .databaseOverview: return true
            default: return false
            }
        }) {
            switch next {
            case .database(let profileID): selectDatabaseWorkspace(profileID: profileID)
            case let .databaseQuery(profileID, queryID): selectDatabaseWorkspace(profileID: profileID, queryID: queryID)
            case .databaseOverview: openDatabaseWorkspace(overview: true)
            default: break
            }
        }
    }

    func closeDatabaseWorkspace(overview: Bool? = nil) {
        guard let overview else {
            workbenchFeature.setVisibility(.databaseServices, isVisible: false)
            editorTabOrderFeature.databaseSelected = false
            editorTabOrderFeature.databaseProfileSelected = nil
            editorTabOrderFeature.databaseQuerySelected = nil
            for item in editorTabOrderFeature.items {
                switch item {
                case .database, .databaseQuery: editorTabOrderFeature.remove(item)
                default: break
                }
            }
            editorTabOrderFeature.remove(.databaseOverview)
            return
        }
        closeDatabaseTab(overview ? .databaseOverview : .database(editorTabOrderFeature.databaseProfileSelected))
    }

    func selectRepositoryDiffTab() {
        editorTabOrderFeature.databaseSelected = false
        guard editorTabOrderFeature.contains(.repositoryDiff) else { return }
        editorTabOrderFeature.focus(.repositoryDiff)
        if !editorTabOrderFeature.repositoryDiffSelected {
            editorTabOrderFeature.repositoryDiffReturnTab = activeEditorTerminalSession.map { .terminal($0.id) }
                ?? activeMediaDocument.map { .media($0.id) } ?? activeDocument.map { .document($0.id) }
        }
        terminalPlacementFeature.activateDocument()
        mediaFeature.deactivate()
        activeDocumentID = nil
        editorTabOrderFeature.repositoryDiffSelected = true
    }

    func moveOpenDocument(_ documentID: UUID, before targetDocumentID: UUID) {
        moveEditorTab(.document(documentID), before: .document(targetDocumentID))
    }

    func moveOpenDocument(_ documentID: UUID, after targetDocumentID: UUID) {
        moveEditorTab(.document(documentID), after: .document(targetDocumentID))
    }

    func moveEditorTab(_ item: EditorTabItem, before target: EditorTabItem) {
        moveEditorTab(item, relativeTo: target, insertAfter: false)
    }

    func moveEditorTab(_ item: EditorTabItem, after target: EditorTabItem) {
        moveEditorTab(item, relativeTo: target, insertAfter: true)
    }

    private func moveEditorTab(
        _ item: EditorTabItem,
        relativeTo target: EditorTabItem,
        insertAfter: Bool
    ) {
        guard item != target, editorTabOrderFeature.contains(target) else { return }
        let moved = insertAfter
            ? editorTabOrderFeature.move(item, after: target)
            : editorTabOrderFeature.move(item, before: target)
        guard moved else { return }

        selectEditorTab(item)
    }

    func selectEditorTab(_ item: EditorTabItem) {
        editorTabOrderFeature.focus(item)
        switch item {
        case .agentConversation: showAgentChatsInEditor()
        case .databaseOverview:
            openDatabaseWorkspace(overview: true)
        case .database(let profileID):
            selectDatabaseWorkspace(profileID: profileID)
        case let .databaseQuery(profileID, queryID):
            selectDatabaseWorkspace(profileID: profileID, queryID: queryID)
        case .repositoryDiff:
            selectRepositoryDiffTab()
        case .document(let documentID):
            guard let document = openDocuments.first(where: { $0.id == documentID }) else {
                editorTabOrderFeature.remove(item)
                return
            }
            documentFeature.reorderDocuments(orderedIDs: editorTabOrderFeature.documentIDs)
            selectEditorDocument(document)
        case .terminal(let sessionID):
            guard let session = terminalSessions.first(where: { $0.id == sessionID }) else {
                editorTabOrderFeature.remove(item)
                return
            }
            let wasAlreadyInEditor = terminalPlacementFeature.editorSessionIDs.contains(sessionID)
            if !wasAlreadyInEditor {
                terminalPlacementFeature.moveToEditor(sessionID)
            }
            terminalPlacementFeature.reorderEditorSessions(
                orderedIDs: editorTabOrderFeature.terminalIDs
            )
            selectEditorTerminalSession(session)
        case .media(let mediaID):
            guard let media = openMediaDocuments.first(where: { $0.id == mediaID }) else {
                editorTabOrderFeature.remove(item)
                return
            }
            selectMediaDocument(media)
        }
    }
    var pendingCloseConfirmationID: UUID? { documentFeature.pendingCloseConfirmationID }
    var pendingCloseDocument: EditorDocument? { documentFeature.pendingCloseDocument }
    var isPendingProjectClose: Bool { documentFeature.isPendingProjectClose }

    var gitChanges: [GitChange] { gitFeatureIfActive?.gitChanges ?? [] }
    var gitTreeStatusProjection: GitTreeStatusProjection {
        gitFeatureIfActive?.gitTreeStatus ?? GitTreeStatusProjection(changes: [])
    }
    func gitChange(for url: URL) -> GitChange? {
        return gitFeatureIfActive?.gitTreeStatus.change(relativePath: url.standardizedFileURL.path)
    }

    func gitTreeStatus(for url: URL, isDirectory: Bool) -> GitChangeKind? {
        return gitFeatureIfActive?.gitTreeStatus.kind(
            relativePath: url.standardizedFileURL.path,
            isDirectory: isDirectory
        )
    }
    func gitLineChangeMarkers(for url: URL) -> [GitLineChangeMarker]? {
        gitFeatureIfActive?.gitLineChangeMarkers[url.standardizedFileURL]
    }
    func effectiveStagingState(for change: GitChange) -> Bool {
        gitFeatureIfActive?.effectiveStagingState(for: change) ?? change.isStaged
    }
    var gitStashes: [GitStash] { gitFeatureIfActive?.gitStashes ?? [] }
    var gitShelves: [GitShelfEntry] { gitFeatureIfActive?.gitShelves ?? [] }
    var gitSaveChangesPolicy: GitSaveChangesPolicy { settings.gitSaveChangesPolicy }
    var isPerformingStashOperation: Bool { gitFeatureIfActive?.isPerformingStashOperation ?? false }
    var isPerformingShelfOperation: Bool { gitFeatureIfActive?.isPerformingShelfOperation ?? false }
    var gitOperationState: GitOperationState? { gitFeatureIfActive?.gitOperationState }
    var gitConsoleEntries: [GitConsoleEntry] { gitFeatureIfActive?.gitConsoleEntries ?? [] }
    var isResolvingGitOperation: Bool { gitFeatureIfActive?.isResolvingGitOperation ?? false }
    var gitRepositoryRoot: URL? { gitFeatureIfActive?.gitRepositoryRoot }
    var currentBranch: String { gitFeatureIfActive?.currentBranch ?? "No Git" }
    var selectedChange: GitChange? {
        get { gitFeatureIfActive?.selectedChange }
        set { gitFeatureIfActive?.selectedChange = newValue }
    }
    var isLoadingDiff: Bool { gitFeatureIfActive?.isLoadingDiff ?? false }
    var isRefreshingGit: Bool { gitFeatureIfActive?.isRefreshingGit ?? false }
    var pendingDiscardChange: GitChange? {
        get { gitFeatureIfActive?.pendingDiscardChange }
        set { gitFeatureIfActive?.pendingDiscardChange = newValue }
    }
    var pendingDiscardHunk: DiffHunkRequest? {
        get { gitFeatureIfActive?.pendingDiscardHunk }
        set { gitFeatureIfActive?.pendingDiscardHunk = newValue }
    }
    var pendingCheckoutConflict: GitCheckoutConflictRequest? {
        get { gitFeatureIfActive?.pendingCheckoutConflict }
        set { gitFeatureIfActive?.pendingCheckoutConflict = newValue }
    }

    var pendingPullStrategy: GitPullStrategyRequest? {
        get { gitFeatureIfActive?.pendingPullStrategy }
        set { gitFeatureIfActive?.pendingPullStrategy = newValue }
    }

    var pendingIntegrationConflict: GitIntegrationConflictRequest? {
        get { gitFeatureIfActive?.pendingIntegrationConflict }
        set { gitFeatureIfActive?.pendingIntegrationConflict = newValue }
    }
    var pendingConflictRollback: GitConflictRollbackRequest? {
        get { gitFeatureIfActive?.pendingConflictRollback }
        set { gitFeatureIfActive?.pendingConflictRollback = newValue }
    }
    var pendingStashRestoreConflict: GitStashRestoreConflictRequest? {
        gitFeatureIfActive?.pendingStashRestoreConflict
    }
    var isStashRestoreConflictNoticeVisible: Bool {
        gitFeatureIfActive?.isStashRestoreConflictNoticeVisible ?? false
    }
    var gitConflictFilterPaths: Set<String> {
        gitFeatureIfActive?.gitConflictFilterPaths ?? []
    }
    var requestedStashReference: String? {
        gitFeatureIfActive?.requestedStashReference
    }
    var recentlyDeletedTag: GitTagDeletion? {
        gitFeatureIfActive?.recentlyDeletedTag
    }
    var recentlyDeletedBranch: GitBranchDeletion? {
        gitFeatureIfActive?.recentlyDeletedBranch
    }
    var isCommitting: Bool { gitFeatureIfActive?.isCommitting ?? false }
    var gitBlameLines: [URL: [GitBlameLine]] { gitFeatureIfActive?.gitBlameLines ?? [:] }
    var gitReferences: [GitReference] { gitFeatureIfActive?.gitReferences ?? [] }
    var gitCommits: [GitCommit] { gitFeatureIfActive?.gitCommits ?? [] }
    var isFilteringGitLog: Bool { gitFeatureIfActive?.isFilteringGitLog ?? false }
    var selectedGitReference: GitReference? {
        get { gitFeatureIfActive?.selectedGitReference }
        set { gitFeatureIfActive?.selectedGitReference = newValue }
    }
    var isShowingAllGitReferences: Bool {
        gitFeatureIfActive?.isShowingAllGitReferences ?? false
    }
    var selectedGitCommit: GitCommit? {
        get { gitFeatureIfActive?.selectedGitCommit }
        set { gitFeatureIfActive?.selectedGitCommit = newValue }
    }
    var selectedGitCommitFiles: [GitCommitFile] { gitFeatureIfActive?.selectedGitCommitFiles ?? [] }
    var selectedGitCommitFilesLoadState: GitCommitFilesLoadState {
        gitFeatureIfActive?.selectedGitCommitFilesLoadState ?? .idle
    }
    var selectedGitCommitFile: GitCommitFile? {
        get { gitFeatureIfActive?.selectedGitCommitFile }
        set { gitFeatureIfActive?.selectedGitCommitFile = newValue }
    }
    var selectedGitCommitDiffContext: GitCommitDiffContext? {
        get { gitFeatureIfActive?.selectedGitCommitDiffContext }
        set { gitFeatureIfActive?.selectedGitCommitDiffContext = newValue }
    }
    var isLoadingMoreGitHistory: Bool { gitFeatureIfActive?.isLoadingMoreGitHistory ?? false }
    var canLoadMoreGitHistory: Bool { gitFeatureIfActive?.canLoadMoreGitHistory ?? false }
    var branchComparison: GitBranchComparison? { gitFeatureIfActive?.branchComparison }
    var isPerformingBranchOperation: Bool { gitFeatureIfActive?.isPerformingBranchOperation ?? false }
    var isCloningRepository: Bool { gitFeatureIfActive?.isCloningRepository ?? false }
    var languageNavigationResults: [LanguageNavigationLocation] {
        languageNavigationState.locations
    }
    var languageNavigationKind: LanguageNavigationResultKind {
        languageNavigationState.kind
    }
    var isLoadingNavigation: Bool {
        languageNavigationState.isLoading
    }
    var isLoadingWorkspace: Bool { workspaceFeature.isLoadingWorkspace }
    var isRefreshingWorkspace: Bool { workspaceFeature.isRefreshingWorkspace }
    var workspaceLoadErrorMessage: String? { workspaceFeature.loadErrorMessage }
    func searchEverywhereActionMatches(query: String) -> [LitheAction] {
        LitheActionRegistry.actions(for: self).filter { $0.matches(query) }
    }

    var localHistoryRequest: LocalHistoryRequest? {
        get { projectHistoryFeatureIfActive?.localHistoryRequest }
        set { projectHistoryFeatureIfActive?.localHistoryRequest = newValue }
    }
    var localHistoryEntries: [LocalHistoryEntry] { projectHistoryFeatureIfActive?.localHistoryEntries ?? [] }
    var selectedLocalHistoryEntry: LocalHistoryEntry? {
        get { projectHistoryFeatureIfActive?.selectedLocalHistoryEntry }
        set { projectHistoryFeatureIfActive?.selectedLocalHistoryEntry = newValue }
    }
    var localHistoryDiffRows: [DiffRow] { (projectHistoryFeatureIfActive?.localHistoryDiffRows ?? []).map(DiffRow.init) }
    var isLoadingLocalHistory: Bool { projectHistoryFeatureIfActive?.isLoadingLocalHistory ?? false }
    var projectLocalHistoryRequest: ProjectLocalHistoryRequest? {
        get { projectHistoryFeatureIfActive?.projectLocalHistoryRequest }
        set { projectHistoryFeatureIfActive?.projectLocalHistoryRequest = newValue }
    }
    var projectLocalHistoryEntries: [LocalHistoryEntry] {
        projectHistoryFeatureIfActive?.projectLocalHistoryEntries ?? []
    }
    var selectedProjectLocalHistoryEntry: LocalHistoryEntry? {
        get { projectHistoryFeatureIfActive?.selectedProjectLocalHistoryEntry }
        set { projectHistoryFeatureIfActive?.selectedProjectLocalHistoryEntry = newValue }
    }
    var projectLocalHistoryDiffRows: [DiffRow] { (projectHistoryFeatureIfActive?.projectLocalHistoryDiffRows ?? []).map(DiffRow.init) }
    var isLoadingProjectLocalHistory: Bool {
        projectHistoryFeatureIfActive?.isLoadingProjectLocalHistory ?? false
    }

    func performShortcutCommand(id: String) {
        workbenchUIRegistry.performAction(id: id, model: self)
    }

    func canPerformShortcutCommand(id: String) -> Bool {
        if let owner = LitheCommandCatalog.moduleOwner(for: id),
           services.moduleRuntime.availableContributions()[owner] == nil { return false }
        return switch id {
        case "open-project", "settings":
            true
        case "save", "find-in-file", "replace-in-file", "go-to-line", "local-history", "reveal-in-finder", "toggle-breakpoint":
            activeDocument != nil
        case "find-next", "find-previous":
            isFindBarVisible && findMatchCount > 0
        case "navigate-back":
            canNavigateBack
        case "navigate-forward":
            canNavigateForward
        case "go-to-definition":
            activeDocument.map { springFeature.handles($0.url) || mybatisFeature.handles($0.url) } == true
                || supportsLanguageServerFeature(.definition)
        case "find-usages":
            supportsLanguageServerFeature(.references)
        case "go-to-implementation":
            supportsLanguageServerFeature(.implementation)
        case "debug-resume", "debug-step-over", "debug-step-into", "debug-step-out":
            genericDebugFeatureIfActive?.state == .paused
        case "close-project", "search-everywhere", "search-in-project",
             "replace-in-project", "project-local-history", "run", "debug",
             "stop-run", "stop-debug", "toggle-terminal", "toggle-problems",
             "toggle-git-log", "toggle-run", "toggle-tests",
             "toggle-debug", "view-breakpoints", "spring-endpoints", "rebuild-java-index":
            workspaceURL != nil
        default:
            false
        }
    }

    func prepareProjectRuntimeSettings() async {
        await runtimeFeature.refreshAvailableRuntimes()
        if let identity = currentWorkspaceIdentity,
           let run = await activateExecutionModule()?.runFeature,
           isCurrentWorkspace(identity) {
            // Seed the form from the saved project toolchain, not the empty value a
            // Run feature holds while it is still reading this project's documents.
            _ = await ensureRunProjectReady(run, for: identity)
            if isCurrentWorkspace(identity) { adoptSavedProjectToolchain(from: run, workspace: identity.url) }
        }
        runtimeFeature.prepare(
            workspaceName: projectName,
            workspaceURL: workspaceURL,
            files: projectFiles,
            mavenProject: mavenFeatureIfActive?.project,
            toolchain: runFeatureIfActive?.projectToolchain,
            mavenSettingsPath: mavenFeatureIfActive?.settingsPath,
            mavenLocalRepositoryPath: mavenFeatureIfActive?.localRepositoryPath,
            mavenExecutablePath: mavenFeatureIfActive?.mavenExecutablePath,
            mavenJavaHomePath: mavenFeatureIfActive?.javaHomePath
        )
    }

    /// `.lithe/run/local.json` owns the project JDK and Maven defaults; the runtime
    /// settings only mirror them. A layer without saved defaults keeps the current
    /// settings, which the next save writes into the layer.
    func adoptSavedProjectToolchain(from run: RunFeatureModel, workspace: URL) {
        guard !run.isLoadingProject,
              run.projectLoadState.hasLoadedDocuments(for: workspace),
              let saved = run.savedProjectToolchain else { return }
        runtimeFeature.adoptProjectToolchain(saved)
    }

    func persistProjectRuntimeSettings() {
        let settings = runtimeFeature.settings
        if let maven = mavenFeatureIfActive {
            maven.updateLocalConfiguration(
                settingsPath: settings.mavenSettingsPath,
                localRepositoryPath: settings.mavenLocalRepositoryPath,
                mavenExecutablePath: settings.mavenExecutableOverride,
                javaHomePath: settings.mavenJavaHomePath
            )
        }
        // Closing Settings persists without an edit. Until the Run feature has read
        // this project's documents, its toolchain is unknown, and saving would
        // overwrite the project defaults with whatever the form was seeded from.
        guard let workspaceURL,
              let run = runFeatureIfActive,
              !run.isLoadingProject,
              run.projectLoadState.hasLoadedDocuments(for: workspaceURL) else { return }
        _ = run.saveProjectToolchain(runtimeFeature.projectToolchainSelection)
    }
}
