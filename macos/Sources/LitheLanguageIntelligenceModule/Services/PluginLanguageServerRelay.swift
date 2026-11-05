import Foundation
import LitheCoreContracts

/// What a plugin backend learns about the language server its own plugin owns
/// (plan API-25), and the preparation status the backend reports in return.
///
/// The relay keeps one fact per server: the generation of the process that is
/// running now. A backend must be able to tell a state or a notification of a
/// replaced process from the current one, so every message carries the
/// generation it belongs to and the relay drops a message whose generation is
/// no longer the live one.
///
/// It holds no session and sends nothing itself. The session manager feeds it
/// state changes and server notifications; the window delivers its outward
/// callbacks to the backend.
@MainActor
package final class PluginLanguageServerRelay {
    /// The state the contract reports; coarser than the session's own states.
    package enum ServerState: String, Equatable, Sendable {
        case starting, running, stopped, crashed
    }

    package struct StateChange: Equatable, Sendable {
        package let pluginID: String
        package let serverID: String
        package let state: ServerState
        package let generation: Int
    }

    package struct ReceivedNotification: Equatable, Sendable {
        package let pluginID: String
        package let serverID: String
        package let generation: Int
        package let notification: PluginServerNotification
    }

    /// The process that is starting or running for a server ID.
    private struct LiveServer {
        let pluginID: String
        let generation: Int
        var state: ServerState
    }

    /// Longest status message shown, in UTF-8 bytes (README, "Language server
    /// host methods").
    package static let maximumMessageBytes = 1024

    /// Raised on every start and never reset, so a generation never repeats
    /// within the window even after the server stopped.
    private var latestGenerations: [String: Int] = [:]
    private var liveServers: [String: LiveServer] = [:]

    /// The newest status each live server's plugin reported.
    package private(set) var statuses: [String: PluginServerStatus] = [:] {
        didSet { if statuses != oldValue { onStatusesChange?(statuses) } }
    }

    package var onStateChange: ((StateChange) -> Void)?
    package var onNotification: ((ReceivedNotification) -> Void)?
    package var onStatusesChange: (([String: PluginServerStatus]) -> Void)?

    package init() {}

    // MARK: Session lifecycle

    /// Follows one server through the session manager's states. `owner` is
    /// the plugin whose package launched the server, nil for a server no
    /// plugin owns; `sessionState` is nil once the session is gone.
    package func serverStateChanged(
        serverID: String,
        owner: String?,
        to sessionState: LanguageServerSessionState?
    ) {
        switch sessionState {
        case .startingProcess, .initializing:
            if let owner { began(serverID: serverID, owner: owner) }
        case .ready:
            reachedRunning(serverID: serverID)
        case .stopped, nil:
            ended(serverID: serverID, as: .stopped)
        case .failed:
            ended(serverID: serverID, as: .crashed)
        case .stopping:
            // The process is still there; `stopped` follows when it is gone.
            break
        }
    }

    /// The generation of the process that is starting or running, if any.
    package func liveGeneration(of serverID: String) -> Int? {
        liveServers[serverID]?.generation
    }

    private func began(serverID: String, owner: String) {
        if let live = liveServers[serverID] {
            // The same process moving from one starting step to the next.
            if live.state == .starting { return }
            // A start without a stop in between replaces the earlier process.
            ended(serverID: serverID, as: .stopped)
        }
        let generation = (latestGenerations[serverID] ?? 0) + 1
        latestGenerations[serverID] = generation
        liveServers[serverID] = LiveServer(pluginID: owner, generation: generation, state: .starting)
        statuses[serverID] = nil
        onStateChange?(StateChange(pluginID: owner, serverID: serverID, state: .starting, generation: generation))
    }

    private func reachedRunning(serverID: String) {
        guard var live = liveServers[serverID], live.state != .running else { return }
        live.state = .running
        liveServers[serverID] = live
        onStateChange?(StateChange(
            pluginID: live.pluginID, serverID: serverID, state: .running, generation: live.generation
        ))
    }

    private func ended(serverID: String, as state: ServerState) {
        guard let live = liveServers.removeValue(forKey: serverID) else { return }
        statuses[serverID] = nil
        onStateChange?(StateChange(
            pluginID: live.pluginID, serverID: serverID, state: state, generation: live.generation
        ))
    }

    // MARK: Notifications from the server

    /// Passes a forwarded server notification on, unless the process that
    /// sent it has been replaced or has ended.
    package func receive(_ notification: PluginServerNotification, serverID: String, generation: Int) {
        guard let live = liveServers[serverID], live.generation == generation else { return }
        onNotification?(ReceivedNotification(
            pluginID: live.pluginID, serverID: serverID, generation: generation, notification: notification
        ))
    }

    // MARK: Status from the backend

    /// Records the status `pluginID`'s backend reports for one of its servers.
    package func setStatus(
        _ status: PluginServerStatus,
        serverID: String,
        pluginID: String
    ) -> Result<Void, PluginHostRequestFailure> {
        // Preparation (importing a build, indexing) starts before the server
        // can answer, so a starting server accepts a status as well.
        guard let live = liveServers[serverID] else { return .failure(.languageServerUnavailable) }
        guard live.pluginID == pluginID else { return .failure(.foreignContribution) }
        statuses[serverID] = status.limitingMessage(toUTF8Bytes: Self.maximumMessageBytes)
        return .success(())
    }
}

/// How far a plugin says its language server is from usable. The host shows
/// it next to the server; it never decides what the server may do.
package struct PluginServerStatus: Equatable, Sendable {
    package enum State: String, Sendable {
        case preparing, ready, degraded, failed
    }

    package let state: State
    /// User-facing text of the plugin, shown as given.
    package let message: String?
    /// A whole number from 0 to 100.
    package let percentage: Int?

    package init(state: State, message: String? = nil, percentage: Int? = nil) {
        self.state = state
        self.message = message
        self.percentage = percentage
    }

    /// Cuts the message on a character boundary, so a plugin cannot fill the
    /// status line with text the host has no room for.
    fileprivate func limitingMessage(toUTF8Bytes limit: Int) -> PluginServerStatus {
        guard let message, message.utf8.count > limit else { return self }
        var kept = ""
        var usedBytes = 0
        for character in message {
            let size = String(character).utf8.count
            if usedBytes + size > limit { break }
            kept.append(character)
            usedBytes += size
        }
        return PluginServerStatus(state: state, message: kept, percentage: percentage)
    }
}
