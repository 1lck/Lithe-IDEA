import Foundation
import LitheCoreContracts
import LitheWorkspaceModule

typealias WorkspaceRebuildResult = LitheWorkspaceModule.WorkspaceRebuildResult
typealias WorkspaceFeatureModel = LitheWorkspaceModule.WorkspaceFeatureModel

@MainActor
extension LitheWorkspaceModule.WorkspaceFeatureModel {
    convenience init(
        operations: any WorkspaceOperations,
        fileOperations: any WorkspaceFileOperations,
        fileStorage: any FileStorage,
        gitWatchContextProvider: any GitWatchContextProviding,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        workspaceSessionStore: any WorkspaceSessionStoring,
        directoryMarkStore: any WorkspaceDirectoryMarkStoring = EmptyWorkspaceDirectoryMarkStore(),
        observationDelay: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        _ = fileStorage
        self.init(
            operations: operations,
            fileOperations: fileOperations,
            gitWatchContextProvider: gitWatchContextProvider,
            directoryWatcherFactory: directoryWatcherFactory,
            workspaceSessionStore: workspaceSessionStore,
            directoryMarkStore: directoryMarkStore,
            observationDelay: observationDelay
        )
    }

    func configure(
        documentsProvider: @escaping @MainActor @Sendable () -> [EditorDocument],
        activeDocumentProvider: @escaping @MainActor @Sendable () -> EditorDocument?,
        selectedSidebarProvider: @escaping @MainActor @Sendable () -> String,
        setSelectedSidebar: @escaping @MainActor @Sendable (String) -> Void,
        restoreSession: @escaping @MainActor @Sendable (WorkspaceSession, [URL]) async -> Void,
        openFile: @escaping @MainActor @Sendable (URL) -> Void,
        notify: @escaping @MainActor @Sendable (String) -> Void,
        recordHistory: @escaping @MainActor @Sendable (URL, LocalHistoryReason) async -> Void,
        relocateHistory: @escaping @MainActor @Sendable (URL, URL) async -> Void,
        relocateOpenDocuments: @escaping @MainActor @Sendable (URL, URL) -> Void,
        closeDocuments: @escaping @MainActor @Sendable (URL) -> Void,
        processExternalChanges: @escaping @MainActor @Sendable ([URL]) -> Bool,
        notifyWorkspaceFileChanges: @escaping @MainActor @Sendable ([WorkspaceFileChange]) -> Void = { _ in },
        reloadProjectServices: @escaping @MainActor @Sendable () async -> Void,
        refreshGit: @escaping @MainActor @Sendable () async -> Void,
        updateHistoryVisibilityRules: @escaping @MainActor @Sendable (FileVisibilityRules) async -> Void,
        onSnapshotLoaded: @escaping @MainActor @Sendable (URL, WorkspaceSnapshot, Bool) async -> Void
    ) {
        configureProjection(
            documentsProvider: {
                documentsProvider().map { WorkspaceDocumentState(url: $0.url, isDirty: $0.isDirty) }
            },
            activeDocumentProvider: {
                activeDocumentProvider().map { WorkspaceDocumentState(url: $0.url, isDirty: $0.isDirty) }
            },
            selectedSidebarProvider: selectedSidebarProvider,
            setSelectedSidebar: setSelectedSidebar,
            restoreSession: restoreSession,
            openFile: openFile,
            notify: notify,
            recordHistory: recordHistory,
            relocateHistory: relocateHistory,
            relocateOpenDocuments: relocateOpenDocuments,
            closeDocuments: closeDocuments,
            processExternalChanges: processExternalChanges,
            notifyWorkspaceFileChanges: notifyWorkspaceFileChanges,
            reloadProjectServices: reloadProjectServices,
            refreshGit: refreshGit,
            updateHistoryVisibilityRules: updateHistoryVisibilityRules,
            onSnapshotLoaded: { snapshot, isInitialLoad in
                await onSnapshotLoaded(snapshot.root.url, snapshot, isInitialLoad)
            },
            warmSearchIndex: { _, _ in },
            updateSearchIndex: { _, _, _ in },
            invalidateSearchIndex: { _, _ in }
        )
    }
}
