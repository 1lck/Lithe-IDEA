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
        // A regeneration replaces the entries a pending freshness check compares.
        javaEntrypointFreshnessObservation = nil
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

    /// Reports Java entries JDT added or removed since the Run list was generated.
    ///
    /// The input fingerprint hashes only the Java sources generation reads, so
    /// a main method added to an existing class is found here instead. The
    /// check never starts the Java service and does not hold the project load
    /// open. While a regeneration already waits for JDT, that refresh replaces
    /// the entries, so there is nothing to compare.
    func checkJavaEntrypointFreshness(
        _ runFeature: RunFeatureModel,
        for identity: WorkspaceIdentity,
        files: [URL]
    ) {
        javaEntrypointFreshnessObservation = nil
        // Without readable generated entries there is nothing to compare, so do
        // not ask JDT for an answer the Run service would discard.
        guard runFeature.configurationStatus == .ready,
              javaEntrypointRefreshObservation == nil,
              files.contains(where: { $0.pathExtension.lowercased() == "java" }),
              let sessions = languageToolingSessionsIfActive else { return }
        if let preparation = sessions.projectPreparation, !preparation.blocksRun {
            Task { [weak self] in
                await self?.compareJavaEntrypoints(runFeature, for: identity, sessions: sessions)
            }
            return
        }
        javaEntrypointFreshnessObservation = sessions.$projectPreparation
            .compactMap { $0 }
            .first(where: { !$0.blocksRun || $0.status == "failed" })
            .sink { [weak self] preparation in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.javaEntrypointFreshnessObservation = nil
                    // A failed import has no answer to compare; generation reports it.
                    guard !preparation.blocksRun, self.isCurrentWorkspace(identity) else { return }
                    await self.compareJavaEntrypoints(runFeature, for: identity, sessions: sessions)
                }
            }
    }

    private func compareJavaEntrypoints(
        _ runFeature: RunFeatureModel,
        for identity: WorkspaceIdentity,
        sessions: LanguageToolingSessionManager
    ) async {
        let entrypoints: JavaEntrypoints
        do {
            entrypoints = try await sessions.javaEntrypoints(rootURL: identity.url)
        } catch {
            sessions.recordLanguageServerLog(
                providerID: "java",
                level: .warning,
                message: "Java entry-point freshness check failed",
                detail: error.localizedDescription
            )
            return
        }
        guard isCurrentWorkspace(identity) else { return }
        await runFeature.reportJavaEntrypointFreshness(entrypoints)
    }

    /// Whether JDT lists `documentURL` as a launchable class in the workspace.
    ///
    /// When the Java service cannot answer, the file is treated as not
    /// launchable and Debug keeps using a project entry, as it did when the
    /// editor text was unavailable.
    func isLaunchableJavaEntrypoint(_ document: EditorDocument?, in workspaceURL: URL) async -> Bool {
        guard let document, document.url.pathExtension.lowercased() == "java" else {
            return false
        }
        guard let sessions = try? await languageSessionsForWorkspaceMaintenance() else {
            return false
        }
        do {
            // Debug can be clicked before the editor's ordinary synchronization
            // task flushes. Make this semantic decision against the exact
            // buffer text, including unsaved Java 25 entry points.
            try sessions.synchronizeLanguageServer(
                for: document.url,
                text: document.text,
                rootURL: workspaceURL
            )
        } catch {
            return false
        }
        guard let entrypoints = try? await sessions.javaEntrypoints(rootURL: workspaceURL) else {
            return false
        }
        let rootPath = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let filePath = document.url.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(prefix) else { return false }
        let relativePath = String(filePath.dropFirst(prefix.count))
        return entrypoints.entries.contains { $0.sourcePath == relativePath }
    }
}
