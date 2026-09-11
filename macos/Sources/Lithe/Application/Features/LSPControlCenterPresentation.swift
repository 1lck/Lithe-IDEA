import Foundation

enum LSPServerStatus: Equatable, Sendable {
    case starting
    case initializing
    case active
    case stopping
    case stopped
    case disabled
    case error
}

enum LSPCapabilityPresentationState: Equatable, Sendable {
    case unknown
    case unsupported
    case available
    case active
}

enum MavenProfilePresentationState: Equatable, Sendable {
    case idle
    case applying
    case partiallyFailed(failed: Int, total: Int)
    case complete
}

enum LSPControlCenterPresenter {
    static func serverStatus(
        isDisabled: Bool,
        sessionState: LanguageServerSessionState?
    ) -> LSPServerStatus {
        if isDisabled {
            return .disabled
        }

        switch sessionState {
        case .startingProcess:
            return .starting
        case .initializing:
            return .initializing
        case .ready:
            return .active
        case .stopping:
            return .stopping
        case .stopped, nil:
            return .stopped
        case .failed:
            return .error
        }
    }

    static func negotiatedCapabilityState(
        _ feature: LanguageServerFeatureSet,
        sessionState: LanguageServerSessionState?,
        features: LanguageServerFeatureSet?
    ) -> LSPCapabilityPresentationState {
        guard sessionState == .ready else {
            return .unknown
        }
        return features?.contains(feature) == true ? .available : .unsupported
    }

    static func reportedServerVersion(_ serverInfo: LanguageServerInfo?) -> String? {
        guard let version = serverInfo?.version?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty else { return nil }
        return version
    }

    static func integrationState(
        isAvailable: Bool,
        isActive: Bool = false
    ) -> LSPCapabilityPresentationState {
        guard isAvailable else {
            return .unsupported
        }
        return isActive ? .active : .available
    }

    static func mavenProfileState(
        _ results: [MavenProfileProjectResult]
    ) -> MavenProfilePresentationState {
        guard !results.isEmpty else { return .idle }
        let failed = results.filter { $0.status == "failed" || $0.status == "timedOut" }.count
        let running = results.contains { $0.status == "running" }
        if running { return .applying }
        if failed > 0 { return .partiallyFailed(failed: failed, total: results.count) }
        return .complete
    }
}
