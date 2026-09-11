import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Owns the asynchronous task associated with Java language-server preparation.
@MainActor
final class JavaLanguageServerPreparationCoordinator {
    typealias SessionsProvider = @MainActor () async throws -> LanguageToolingSessionManager
    typealias OwnershipCheck = @MainActor () -> Bool
    typealias FailureHandler = @MainActor (JavaLanguageServerPreparationFailure) -> Void
    typealias StartedHandler = @MainActor (UUID) -> Void

    func schedule(
        for owner: JavaLanguageServerPreparationOwner,
        operation: @escaping @MainActor () async -> Void
    ) {
        owner.task?.cancel()
        let task = Task { @MainActor [weak owner] in
            guard owner != nil else { return }
            await operation()
        }
        owner.task = task
    }

    func cancel(_ owner: JavaLanguageServerPreparationOwner?) {
        owner?.cancel()
    }

    func prepareAndStart(
        owner: JavaLanguageServerPreparationOwner,
        workspaceURL: URL,
        runtimePreparation: @escaping @MainActor () async
            -> ProjectRuntimeService.JavaLanguageServerRuntimePreparation,
        sessionsProvider: @escaping SessionsProvider,
        ownsPreparation: @escaping OwnershipCheck,
        onStarted: @escaping StartedHandler,
        onFailure: @escaping FailureHandler
    ) {
        schedule(for: owner) { @MainActor [weak owner] in
            guard let owner else { return }
            do {
                let sessions = try await sessionsProvider()
                guard !Task.isCancelled, ownsPreparation() else { return }
                sessions.recordLanguageServerLog(
                    providerID: "java",
                    operationID: owner.operationID,
                    level: .info,
                    message: "Bundled JDK preparation started",
                    detail: nil
                )
                let preparation = await runtimePreparation()
                guard !Task.isCancelled, ownsPreparation() else { return }
                switch preparation {
                case .unprepared:
                    return
                case .failed(let message):
                    sessions.recordLanguageServerLog(
                        providerID: "java",
                        operationID: owner.operationID,
                        level: .error,
                        message: "Bundled JDK preparation failed",
                        detail: message
                    )
                    onFailure(.failed(message: message))
                    return
                case .ready(let executableURL):
                    sessions.recordLanguageServerLog(
                        providerID: "java",
                        operationID: owner.operationID,
                        level: .info,
                        message: "Bundled JDK preparation succeeded",
                        detail: executableURL.path
                    )
                }
                let startedOperationID = try sessions.startLanguageServer(
                    providerID: "java",
                    rootURL: workspaceURL,
                    operationID: owner.operationID
                )
                guard ownsPreparation() else { return }
                onStarted(startedOperationID)
            } catch {
                guard ownsPreparation() else { return }
                let sessionFailure = (error as? LanguageServerSessionStartError)?.failure
                onFailure(
                    sessionFailure?.isTimedOut == true
                        ? .timedOut(message: error.localizedDescription)
                        : .failed(message: error.localizedDescription)
                )
            }
        }
    }

    func notifyWorkspaceFileChanges(
        _ changes: [WorkspaceFileChange],
        workspaceURL: URL,
        projectFiles: [URL],
        openDocuments: [EditorDocument],
        policy: @escaping (URL, [URL], [URL]) -> JavaWorkspacePolicyResult?,
        sessions: LanguageToolingSessionManager?
    ) {
        guard let workspacePolicy = policy(
            workspaceURL,
            projectFiles,
            changes.map(\.fileURL)
        ) else { return }
        let changeKinds = Dictionary(
            uniqueKeysWithValues: changes.map { ($0.fileURL.standardizedFileURL, $0.kind) }
        )
        let openJavaURLs = Set(openDocuments.compactMap { document in
            document.url.pathExtension.lowercased() == "java"
                ? document.url.standardizedFileURL
                : nil
        })
        let languageServerChanges = workspacePolicy.changes.compactMap {
            change -> LanguageServerWorkspaceFileChange? in
            guard change.kind == .source || change.kind == .buildConfiguration else {
                return nil
            }
            let url = change.url.standardizedFileURL
            guard !openJavaURLs.contains(url), let kind = changeKinds[url] else {
                return nil
            }
            let languageServerKind: LanguageServerWorkspaceFileChangeKind = switch kind {
            case .created: .created
            case .changed: .changed
            case .deleted: .deleted
            }
            return LanguageServerWorkspaceFileChange(fileURL: url, kind: languageServerKind)
        }
        guard !languageServerChanges.isEmpty else { return }
        do {
            try sessions?.notifyWorkspaceFilesChanged(
                providerID: "java",
                changes: languageServerChanges
            )
        } catch {
            sessions?.recordLanguageServerLog(
                providerID: "java",
                level: .error,
                message: "Java workspace change notification failed",
                detail: error.localizedDescription
            )
        }
    }

    func handleSessionState(
        _ state: LanguageServerSessionState,
        operationID: UUID?,
        javaFeature: JavaFeatureModel,
        workspaceURL: URL?,
        onReady: @MainActor () -> Void,
        onFailure: @MainActor (JavaLanguageServerPreparationFailure) -> Void
    ) {
        guard let operationID,
              javaFeature.languageServerOperationID == operationID,
              let workspaceURL else { return }
        switch state {
        case .ready:
            javaFeature.markLanguageServerReady(
                workspaceURL: workspaceURL.standardizedFileURL,
                operationID: operationID
            )
            onReady()
        case .failed(let failure):
            onFailure(
                failure.isTimedOut
                    ? .timedOut(message: failure.message ?? "JDTLS failed to start.")
                    : .failed(message: failure.message ?? "JDTLS failed to start.")
            )
        case .startingProcess, .initializing, .stopping, .stopped:
            break
        }
    }
}
