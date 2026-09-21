import Combine
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheLanguageIntelligenceModule

/// Java entry points come from JDT: which classes are launchable is its
/// answer, and the Run list, launch, and Debug all ask it through Core.
///
/// Note: 入口点归属见 .agents/notes/implemented/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md
extension AppModel {
    /// Asks JDT which classes can be launched, then regenerates the Run list
    /// from its answer. While JDT is still preparing the project the previous
    /// entries stay, and the list refreshes once preparation settles.
    func generateFromJavaEntrypoints(
        _ runFeature: RunFeatureModel,
        for identity: WorkspaceIdentity
    ) async {
        let (discovery, sessions) = await discoverJavaEntrypoints(for: identity)
        guard isCurrentWorkspace(identity) else { return }
        await runFeature.generateRunConfigurations(javaDiscovery: discovery)
        if discovery == .pending, let sessions {
            refreshJavaEntrypointsWhenPrepared(for: identity, sessions: sessions)
        }
    }

    /// Asks JDT which classes can be launched once it has prepared the project.
    ///
    /// Asking earlier would return a partial list mid-import, so an unprepared
    /// workspace reports `.pending` and generation keeps the previous entries.
    func discoverJavaEntrypoints(
        for identity: WorkspaceIdentity
    ) async -> (JavaEntrypointDiscovery, LanguageToolingSessionManager?) {
        javaEntrypointRefreshObservation = nil
        let hasJavaSources = workspaceFeature.appliedSnapshot?.files
            .contains { $0.pathExtension.lowercased() == "java" } ?? false
        guard hasJavaSources else { return (.notJava, nil) }
        let sessions: LanguageToolingSessionManager
        do {
            sessions = try await languageSessionsForWorkspaceMaintenance()
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
        guard isCurrentWorkspace(identity) else { return (.pending, nil) }
        guard let preparation = sessions.projectPreparation else {
            // Nothing started the Java service for this workspace yet. Asking
            // starts it the way a launch does; its outcome reaches the refresh
            // through `projectPreparation`, so the result here is not needed.
            Task { [sessions] in _ = try? await sessions.javaEntrypoints(rootURL: identity.url) }
            return (.pending, sessions)
        }
        if preparation.blocksRun {
            return preparation.status == "failed"
                ? (.failed(String(localized: "The Java language service failed to prepare the project.")), sessions)
                : (.pending, sessions)
        }
        do {
            return (.discovered(try await sessions.javaEntrypoints(rootURL: identity.url)), sessions)
        } catch {
            return (.failed(error.localizedDescription), sessions)
        }
    }

    /// Regenerates once JDT has finished (or failed) preparing the project.
    func refreshJavaEntrypointsWhenPrepared(
        for identity: WorkspaceIdentity,
        sessions: LanguageToolingSessionManager
    ) {
        javaEntrypointRefreshObservation = sessions.$projectPreparation
            .compactMap { $0 }
            .first(where: { !$0.blocksRun || $0.status == "failed" })
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.javaEntrypointRefreshObservation = nil
                    guard self.isCurrentWorkspace(identity) else { return }
                    await self.generateRunConfigurations()
                }
            }
    }

    /// Whether JDT lists `documentURL` as a launchable class in the workspace.
    ///
    /// When the Java service cannot answer, the file is treated as not
    /// launchable and Debug keeps using a project entry, as it did when the
    /// editor text was unavailable.
    func isLaunchableJavaEntrypoint(_ documentURL: URL?, in workspaceURL: URL) async -> Bool {
        guard let documentURL, documentURL.pathExtension.lowercased() == "java" else {
            return false
        }
        guard let sessions = try? await languageSessionsForWorkspaceMaintenance(),
              let entrypoints = try? await sessions.javaEntrypoints(rootURL: workspaceURL) else {
            return false
        }
        let rootPath = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let filePath = documentURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(prefix) else { return false }
        let relativePath = String(filePath.dropFirst(prefix.count))
        return entrypoints.entries.contains { $0.sourcePath == relativePath }
    }
}
