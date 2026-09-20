import Foundation
import LitheCoreContracts

extension AppModel {
    func resolveJavaLaunchPreparation(
        _ preparation: JavaLaunchPreparation,
        identity: WorkspaceIdentity
    ) async throws -> JavaDebugLaunchTarget {
        switch preparation {
        case .ready(let target):
            return target
        case .buildFailed(let target, let failure):
            guard isCurrentWorkspace(identity), !Task.isCancelled else {
                throw CancellationError()
            }
            if settings.javaBuildFailurePolicy(for: identity.url) == .alwaysContinue {
                return target
            }
            let resolution = await requestJavaLaunchDecision(
                failure: failure,
                identity: identity
            )
            guard isCurrentWorkspace(identity), !Task.isCancelled else {
                throw CancellationError()
            }
            switch resolution {
            case .runOnce:
                return target
            case .alwaysContinue:
                settings.setJavaBuildFailurePolicy(.alwaysContinue, for: identity.url)
                return target
            case .rebuildIndex:
                rebuildJavaIndex()
                throw CancellationError()
            case .cancel:
                throw CancellationError()
            }
        }
    }

    func completeJavaLaunchDecision(
        _ resolution: JavaLaunchDecisionResolution,
        requestID: UUID? = nil
    ) {
        if let requestID, pendingJavaLaunchDecision?.id != requestID {
            return
        }
        guard let continuation = pendingJavaLaunchDecisionContinuation else {
            pendingJavaLaunchDecision = nil
            return
        }
        pendingJavaLaunchDecisionContinuation = nil
        pendingJavaLaunchDecision = nil
        continuation.resume(returning: resolution)
    }

    func cancelPendingJavaLaunchDecision() {
        completeJavaLaunchDecision(.cancel)
    }

    func askAgainForJavaBuildFailures() {
        guard let workspaceURL else { return }
        settings.setJavaBuildFailurePolicy(.ask, for: workspaceURL)
        objectWillChange.send()
    }

    var alwaysContinuesAfterJavaBuildFailures: Bool {
        guard let workspaceURL else { return false }
        return settings.javaBuildFailurePolicy(for: workspaceURL) == .alwaysContinue
    }

    private func requestJavaLaunchDecision(
        failure: JavaLaunchBuildFailure,
        identity: WorkspaceIdentity
    ) async -> JavaLaunchDecisionResolution {
        cancelPendingJavaLaunchDecision()
        let request = PendingJavaLaunchDecision(
            id: UUID(),
            workspaceURL: identity.url,
            failure: failure
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrentWorkspace(identity) else {
                    continuation.resume(returning: .cancel)
                    return
                }
                pendingJavaLaunchDecisionContinuation = continuation
                pendingJavaLaunchDecision = request
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.pendingJavaLaunchDecision?.id == request.id else { return }
                self?.cancelPendingJavaLaunchDecision()
            }
        }
    }
}
