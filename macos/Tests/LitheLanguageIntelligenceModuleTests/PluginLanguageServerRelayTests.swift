import Foundation
import LitheCoreContracts
@testable import LitheLanguageIntelligenceModule
import Testing

/// What a plugin backend learns about its own language server (plan API-25):
/// one generation per process, states in order, and nothing from a process
/// that was replaced.
@MainActor
struct PluginLanguageServerRelayTests {
    private let relay = PluginLanguageServerRelay()
    private let states = StateLog()

    init() {
        let states = states
        relay.onStateChange = { states.changes.append($0) }
    }

    private func change(_ state: PluginLanguageServerRelay.ServerState, generation: Int) -> PluginLanguageServerRelay.StateChange {
        .init(pluginID: "tool", serverID: "scala", state: state, generation: generation)
    }

    /// `Result<Void, _>` is not `Equatable`, so the tests compare the failure.
    private func failure(of outcome: Result<Void, PluginHostRequestFailure>) -> PluginHostRequestFailure? {
        if case .failure(let failure) = outcome { return failure }
        return nil
    }

    // MARK: States

    @Test
    func aStartRunsThroughStartingToRunningUnderOneGeneration() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .initializing)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .ready)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .ready)

        // The two starting steps and the repeated ready are one process.
        #expect(states.changes == [change(.starting, generation: 1), change(.running, generation: 1)])
        #expect(relay.liveGeneration(of: "scala") == 1)
    }

    @Test
    func aStoppedServerReportsStoppedAndTheNextStartGetsANewGeneration() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .stopped)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)

        #expect(states.changes == [
            change(.starting, generation: 1), change(.stopped, generation: 1), change(.starting, generation: 2),
        ])
        #expect(relay.liveGeneration(of: "scala") == 2)
    }

    @Test
    func aFailureReportsCrashedAndLeavesNoLiveProcess() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .ready)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .failed(LanguageServerSessionFailure(code: "exited")))
        // The session going away after a failure adds nothing.
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: nil)

        #expect(states.changes.last == change(.crashed, generation: 1))
        #expect(states.changes.count == 3)
        #expect(relay.liveGeneration(of: "scala") == nil)
    }

    @Test
    func aStartWithoutAStopReplacesTheEarlierProcess() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .ready)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)

        #expect(Array(states.changes.suffix(2)) == [change(.stopped, generation: 1), change(.starting, generation: 2)])
    }

    @Test
    func aStoppingServerIsStillTheSameProcess() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .ready)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .stopping)

        #expect(states.changes.count == 2)
        #expect(relay.liveGeneration(of: "scala") == 1)
    }

    @Test
    func aServerNoPluginOwnsReportsNothing() {
        relay.serverStateChanged(serverID: "scala", owner: nil, to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: nil, to: .ready)

        #expect(states.changes.isEmpty)
        #expect(relay.liveGeneration(of: "scala") == nil)
    }

    // MARK: Notifications

    @Test
    func aNotificationOfTheLiveProcessIsPassedOn() {
        let received = NotificationLog()
        relay.onNotification = { received.items.append($0) }
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        let notification = PluginServerNotification(method: "metals/status", params: .object(["text": .string("ok")]), truncated: false)

        relay.receive(notification, serverID: "scala", generation: 1)

        #expect(received.items == [.init(pluginID: "tool", serverID: "scala", generation: 1, notification: notification)])
    }

    @Test
    func aNotificationOfAReplacedOrEndedProcessIsDropped() {
        let received = NotificationLog()
        relay.onNotification = { received.items.append($0) }
        let notification = PluginServerNotification(method: "metals/status", params: nil, truncated: true)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .stopped)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)

        relay.receive(notification, serverID: "scala", generation: 1)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .stopped)
        relay.receive(notification, serverID: "scala", generation: 2)

        #expect(received.items.isEmpty)
    }

    // MARK: Status

    @Test
    func aServersPluginCanReportItsStatusWhileTheServerStarts() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)

        let outcome = relay.setStatus(PluginServerStatus(state: .preparing, message: "Importing", percentage: 10), serverID: "scala", pluginID: "tool")

        #expect(failure(of: outcome) == nil)
        #expect(relay.statuses["scala"] == PluginServerStatus(state: .preparing, message: "Importing", percentage: 10))
    }

    @Test
    func aStatusForAServerThatIsNotLiveIsUnavailable() {
        let outcome = relay.setStatus(PluginServerStatus(state: .ready), serverID: "scala", pluginID: "tool")

        #expect(failure(of: outcome) == .languageServerUnavailable)
        #expect(relay.statuses.isEmpty)
    }

    @Test
    func aPluginCannotReportTheStatusOfAnotherPluginsServer() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)

        let outcome = relay.setStatus(PluginServerStatus(state: .failed), serverID: "scala", pluginID: "other")

        #expect(failure(of: outcome) == .foreignContribution)
        #expect(relay.statuses.isEmpty)
    }

    @Test
    func aLongMessageIsCutOnACharacterBoundary() throws {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        // Each character takes three bytes, so the cut falls between two.
        let long = String(repeating: "进", count: 400)

        _ = relay.setStatus(PluginServerStatus(state: .degraded, message: long), serverID: "scala", pluginID: "tool")

        let kept = try #require(relay.statuses["scala"]?.message)
        #expect(kept.utf8.count <= PluginLanguageServerRelay.maximumMessageBytes)
        #expect(kept.utf8.count == 1023)
        #expect(long.hasPrefix(kept))
    }

    @Test
    func aStatusEndsWithTheProcessItDescribed() {
        let seen = StatusLog()
        relay.onStatusesChange = { seen.maps.append($0) }
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        _ = relay.setStatus(PluginServerStatus(state: .preparing), serverID: "scala", pluginID: "tool")

        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .stopped)

        #expect(relay.statuses.isEmpty)
        #expect(seen.maps.last?.isEmpty == true)
        #expect(seen.maps.count == 2)
    }

    @Test
    func aReplacedProcessTakesItsStatusWithIt() {
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .ready)
        _ = relay.setStatus(PluginServerStatus(state: .degraded), serverID: "scala", pluginID: "tool")

        // A start without a stop replaces the process; its status described
        // the old one.
        relay.serverStateChanged(serverID: "scala", owner: "tool", to: .startingProcess)

        #expect(relay.statuses["scala"] == nil)
        #expect(relay.liveGeneration(of: "scala") == 2)
    }
}

@MainActor
private final class StateLog {
    var changes: [PluginLanguageServerRelay.StateChange] = []
}

@MainActor
private final class NotificationLog {
    var items: [PluginLanguageServerRelay.ReceivedNotification] = []
}

@MainActor
private final class StatusLog {
    var maps: [[String: PluginServerStatus]] = []
}
