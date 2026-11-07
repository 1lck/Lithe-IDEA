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

/// A projection of session state, never a second lifecycle owner.
struct LSPStatusBarServer: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let status: LSPServerStatus
    let version: String?

    var canStop: Bool { status != .stopped && status != .disabled }
}

/// An enabled plugin's server declaration. The language ID only routes existing
/// session controls; it never supplies the server's visible name.
struct LanguageServerRegistration: Equatable, Sendable {
    let id: String
    let pluginID: String
    let executableNames: [String]

    init(id: String, pluginID: String, executableNames: [String] = []) {
        self.id = id
        self.pluginID = pluginID
        self.executableNames = executableNames
    }
}

struct LanguageServerRuntimeSnapshot: Equatable {
    var states: [String: LanguageServerSessionState] = [:]
    var infos: [String: LanguageServerInfo] = [:]
}

enum LSPCapabilityPresentationState: Equatable, Sendable {
    case unknown
    case unsupported
    case available
    case active
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

    static func statusBarServers(
        registrations: [LanguageServerRegistration],
        states: [String: LanguageServerSessionState],
        infos: [String: LanguageServerInfo],
        disabledProviderIDs: Set<String>
    ) -> [LSPStatusBarServer] {
        registrations.map { registration in
            let status = serverStatus(
                isDisabled: disabledProviderIDs.contains(registration.id),
                sessionState: states[registration.id]
            )
            let executableName = registration.executableNames.lazy
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return LSPStatusBarServer(
                id: registration.id,
                displayName: executableName ?? registration.pluginID,
                status: status,
                version: status == .active ? reportedServerVersion(infos[registration.id]) : nil
            )
        }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// A failed server must remain discoverable even when another is healthy.
    static func aggregateStatus(_ servers: [LSPStatusBarServer]) -> LSPServerStatus {
        [.error, .starting, .initializing, .stopping, .active, .stopped, .disabled].first { status in
            servers.contains { $0.status == status }
        } ?? .stopped
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
}
