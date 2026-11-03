import Foundation
import Sparkle
import Testing
@testable import Lithe

/// Opt-in end-to-end update through the real Sparkle engine and the loopback relay.
///
/// Requires a local feed prepared outside the test: `LITHE_E2E_APP` is a signed
/// fixture bundle at the old version, `LITHE_E2E_FEED` the appcast URL, and
/// `LITHE_E2E_EXPECTED_BUILD` the build the bundle must carry after installation.
@Suite("Sparkle relay end-to-end")
struct SparkleRelayEndToEndTests {
    static let environment = ProcessInfo.processInfo.environment
    static var enabled: Bool { environment["LITHE_E2E_APP"] != nil }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(2))) @MainActor
    func updateDownloadsThroughRelayAndInstalls() async throws {
        let environment = Self.environment
        let app = URL(fileURLWithPath: try #require(environment["LITHE_E2E_APP"]))
        let feed = try #require(environment["LITHE_E2E_FEED"])
        let expectedBuild = try #require(environment["LITHE_E2E_EXPECTED_BUILD"])
        let partials = URL(fileURLWithPath: try #require(environment["LITHE_E2E_PARTIALS"]))
        let bundle = try #require(Bundle(url: app))

        let relay = UpdateDownloadRelay(store: UpdateDownloadPartialStore(directory: partials))
        defer { relay.stop() }
        let driver = HeadlessUserDriver()
        let delegate = RelayingDelegate(feed: feed, relay: relay)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
        try updater.start()
        updater.checkForUpdates()

        let installed = await poll(seconds: 90) {
            driver.error != nil || Self.build(of: app) == expectedBuild
        }
        if environment["LITHE_E2E_EXPECT_FAILURE"] != nil {
            let failure = try #require(relay.lastFailure)
            print("E2E failure=\(failure) message=\(UpdateChecker.downloadFailureMessage(failure))")
            #expect(driver.error != nil && Self.build(of: app) != expectedBuild)
            return
        }
        if let error = driver.error {
            Issue.record("Sparkle reported \(error) relayFailure=\(String(describing: relay.lastFailure))")
        }
        #expect(installed && Self.build(of: app) == expectedBuild)
        #expect(delegate.relayedURLs.count == 1, "\(delegate.relayedURLs)")
        print("E2E relayed=\(delegate.relayedURLs.map(\.absoluteString)) events=\(driver.events)")
    }

    static func build(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleVersion"] as? String
    }

    @MainActor
    private func poll(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            // test-stability: allow(swift-real-sleep) reason: Sparkle's out-of-process installer replaces the bundle without a callback, so poll it under a local deadline.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

private final class RelayingDelegate: NSObject, SPUUpdaterDelegate {
    let feed: String
    let relay: UpdateDownloadRelay
    var relayedURLs: [URL] = []

    init(feed: String, relay: UpdateDownloadRelay) {
        self.feed = feed
        self.relay = relay
    }

    func feedURLString(for updater: SPUUpdater) -> String? { feed }

    // Mirrors `UpdateChecker.updater(_:willDownloadUpdate:with:)`.
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if let url = request.url, let relayed = relay.relayURL(for: url) {
            relayedURLs.append(url)
            request.url = relayed
        }
    }
}

/// Accepts every offer and install prompt without presenting UI.
private final class HeadlessUserDriver: NSObject, SPUUserDriver {
    var events: [String] = []
    var error: Error?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        events.append("permission")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { events.append("check") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append("found:\(appcastItem.versionString)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        events.append("notFound")
        self.error = error
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        events.append("error")
        self.error = error
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { events.append("download") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { events.append("length:\(expectedContentLength)") }
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { events.append("extract") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append("ready")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        events.append("installing")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        events.append("installed")
        acknowledgement()
    }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() { events.append("dismiss") }
}
