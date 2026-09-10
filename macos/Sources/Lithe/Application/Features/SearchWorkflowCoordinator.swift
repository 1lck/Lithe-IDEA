import Combine
import Foundation
import LitheSearchModule

/// Coordinates workspace and everywhere searches for one workspace session.
@MainActor
final class SearchWorkflowCoordinator {
    private let session: SearchSessionFeatureModel
    private let settings: AppSettings
    private let activate: () async throws -> SearchFeatureModel
    private let workspace: () -> URL?
    private let notify: (String) -> Void
    private let markIdle: () -> Void

    init(
        session: SearchSessionFeatureModel,
        settings: AppSettings,
        activate: @escaping () async throws -> SearchFeatureModel,
        workspace: @escaping () -> URL?,
        notify: @escaping (String) -> Void,
        markIdle: @escaping () -> Void
    ) {
        self.session = session
        self.settings = settings
        self.activate = activate
        self.workspace = workspace
        self.notify = notify
        self.markIdle = markIdle
    }

    func searchProject(options: ProjectSearchOptions) async {
        guard let root = workspace() else { return }
        do {
            let feature = try await activate()
            let query = session.query
            await feature.searchProject(
                at: root,
                query: query,
                options: options,
                visibilityRules: settings.fileVisibilityRules.searchRules,
                isCurrent: { [weak session, workspace] in
                    session?.query == query && workspace() == root
                }
            )
            markIdle()
        } catch {
            notify(error.localizedDescription)
        }
    }

    func searchEverywhere(query: String, options: ProjectSearchOptions) async {
        guard let root = workspace() else { return }
        do {
            let feature = try await activate()
            await feature.searchEverywhere(
                at: root,
                query: query,
                options: options,
                visibilityRules: settings.fileVisibilityRules.searchRules,
                isCurrent: { [weak session, workspace] in
                    session?.isSearchEverywhereVisible == true && workspace() == root
                }
            )
            markIdle()
        } catch {
            notify(error.localizedDescription)
        }
    }
}
