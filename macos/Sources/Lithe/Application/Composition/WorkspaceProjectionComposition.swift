import Foundation
import LitheCoreContracts
import LitheSearchModule
import LitheLocalHistoryModule
import LitheGitModule

/// Connects workspace projection ports to their owners without routing editor
/// state through the AppModel compatibility facade.
@MainActor
enum WorkspaceProjectionComposition {
    static func configure(model: AppModel) {
        let graph = model.featureGraph
        let document = graph.document
        let workbench = graph.workbench
        let editorSession = graph.editorSession
        let notification = graph.notification
        graph.workspace.configureProjection(
            documentsProvider: { [weak document] in
                document?.openDocuments.map { WorkspaceDocumentState(url: $0.url, isDirty: $0.isDirty) } ?? []
            },
            activeDocumentProvider: { [weak document] in
                document?.activeDocument.map { WorkspaceDocumentState(url: $0.url, isDirty: $0.isDirty) }
            },
            selectedSidebarProvider: { [weak workbench] in
                workbench?.selectedSidebar.rawValue ?? SidebarDestination.project.rawValue
            },
            setSelectedSidebar: { [weak workbench] rawValue in
                workbench?.selectedSidebar = SidebarDestination(rawValue: rawValue) ?? .project
            },
            restoreSession: { [weak workbench, weak editorSession] session, availableFiles in
                let sidebar = SidebarDestination(rawValue: session.selectedSidebar) ?? .project
                workbench?.selectedSidebar = sidebar.isAvailable ? sidebar : .project
                await editorSession?.restoreDocuments(
                    orderedPaths: session.openPaths,
                    activePath: session.activePath,
                    availableFiles: availableFiles
                )
            },
            openFile: { [weak model] url in model?.openFile(url) },
            notify: { [weak notification] message in notification?.show(message) },
            recordHistory: { [weak model] url, reason in
                guard let feature = await model?.activateHistoryModule() else { return }
                await feature.recordHistory(containedIn: url, reason: reason)
            },
            relocateHistory: { [weak model] source, destination in
                guard let feature = await model?.activateHistoryModule() else { return }
                await feature.relocateHistory(from: source, to: destination)
            },
            relocateOpenDocuments: { [weak document] source, destination in
                document?.relocateOpenDocuments(from: source, to: destination)
            },
            closeDocuments: { [weak document] url in document?.closeDocuments(containedIn: url) },
            processExternalChanges: { [weak document, weak model] paths in
                let conflict = document?.processExternalChanges(paths) ?? false
                model?.withHistoryModule { $0.recordExternalChanges(paths) }
                return conflict
            },
            notifyWorkspaceFileChanges: { [weak model] changes in
                model?.handleJavaWorkspaceFileChanges(changes)
            },
            reloadProjectServices: { [weak model] in
                guard let model, let workspaceURL = model.workspaceURL else { return }
                await model.loadProjectServicesForAppliedSnapshot(at: workspaceURL)
            },
            refreshGit: { [weak model] in
                await model?.gitFeatureIfActive?.refreshGit()
            },
            updateHistoryVisibilityRules: { [weak model] rules in
                guard let feature = await model?.activateHistoryModule() else { return }
                await feature.updateVisibilityRules(rules.localHistoryRules)
            },
            onSnapshotLoaded: { [weak model] snapshot, isInitialLoad in
                guard let model else { return }
                // Loading a ready inventory also resumes deferred run actions.
                await model.loadProjectServices(
                    at: snapshot.root.url,
                    files: snapshot.files,
                    snapshotID: snapshot.id,
                    resumesDeferredRunAction: true
                )
                if isInitialLoad {
                    model.projectHistoryFeatureIfActive?.seed(files: snapshot.files)
                }
            },
            warmSearchIndex: { [weak model] workspaceURL, rules in
                model?.searchFeatureIfActive?.warmIndex(at: workspaceURL, visibilityRules: rules.searchRules)
            },
            updateSearchIndex: { [weak model] workspaceURL, paths, rules in
                await model?.searchFeatureIfActive?.updateIndex(
                    at: workspaceURL,
                    changedPaths: paths,
                    visibilityRules: rules.searchRules
                )
            },
            invalidateSearchIndex: { [weak model] workspaceURL, rules in
                model?.searchFeatureIfActive?.invalidateIndex(at: workspaceURL, visibilityRules: rules.searchRules)
            }
        )
    }
}
