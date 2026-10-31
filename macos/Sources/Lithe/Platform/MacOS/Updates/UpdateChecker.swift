import AppKit
import Sparkle
import Foundation
import LitheModuleAPI
import Combine

struct UpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: UpdateNoticeAction
}

enum UpdateNoticeAction {
    case open(URL)
    case dismiss
}

struct UpdateInfo: Equatable, Sendable {
    let currentVersion: String
    let targetVersion: String
    let releaseDate: String?
    let releaseNotes: String?
    let releaseURL: URL
    var isPreview = false
    var currentBuild: String? = nil
    var targetBuild: String? = nil
    var currentBuildDate: String? = nil
}

struct UpdateBuildIdentity: Equatable {
    let isPreview: Bool
    let build: String
    let buildDate: String?
    let releaseURL: URL

    init(info: [String: Any]) {
        isPreview = AppUpdateChannel.installed(info: info) == .autobuild
        build = info["CFBundleVersion"] as? String ?? "0"
        buildDate = info["LitheBuildTimestamp"] as? String
        releaseURL = (info["LitheUpdateReleaseURL"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!
    }

    func updateInfo(version: String, targetVersion: String, targetBuild: String,
                    date: Date?, notes: String?, infoURL: URL? = nil) -> UpdateInfo {
        UpdateInfo(currentVersion: version, targetVersion: targetVersion,
            releaseDate: date.map { ISO8601DateFormatter().string(from: $0) },
            releaseNotes: isPreview ? nil : notes, releaseURL: infoURL ?? releaseURL,
            isPreview: isPreview, currentBuild: build, targetBuild: targetBuild, currentBuildDate: buildDate)
    }
}

struct UpdateDownloadProgress: Equatable, Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64?

    static let initial = UpdateDownloadProgress(downloadedBytes: 0, totalBytes: nil)

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }

    var percentage: Int? {
        guard let fractionCompleted else { return nil }
        return Int((fractionCompleted * 100).rounded())
    }

    var byteCountDescription: String {
        let downloaded = ByteCountFormatter.string(
            fromByteCount: downloadedBytes,
            countStyle: .file
        )
        guard let totalBytes else {
            return downloaded
        }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String, url: URL)
    case downloading(version: String, progress: UpdateDownloadProgress)
    case installing(version: String)
    case waitingForTermination
    case upToDate(version: String)
    case failed(code: UpdateErrorCode, message: String)
}

enum UpdateErrorCode: String, Equatable, Sendable {
    case noPublishedRelease = "no_published_release"
    case invalidResponse = "invalid_response"
    case rateLimited = "rate_limited"
    case httpStatus = "http_status"
    case timedOut = "timed_out"
    case tlsOrProxyFailure = "tls_or_proxy_failure"
    case connectionFailed = "connection_failed"
    case invalidManifest = "invalid_manifest"
    case unsupportedSchema = "unsupported_schema"
    case noCompatibleAsset = "no_compatible_asset"
    case checksumMismatch = "checksum_mismatch"
    case downloadFailed = "download_failed"
    case installFailed = "install_failed"
    case notAppBundle = "not_app_bundle"
    case appNotFoundInDiskImage = "app_not_found_in_disk_image"
}

struct UpdateEndpointConfiguration: Equatable {
    static let productionManifestURL = URL(
        string: "https://github.com/1lck/Lithe-IDEA/releases/latest/download/latest-macos.json"
    )!

    let manifestURL: URL
    let allowsLocalHTTP: Bool

    static let production = UpdateEndpointConfiguration(
        manifestURL: productionManifestURL,
        allowsLocalHTTP: false
    )

    init(manifestURL: URL, allowsLocalHTTP: Bool = false) {
        self.manifestURL = manifestURL
        self.allowsLocalHTTP = allowsLocalHTTP
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        switch host.lowercased() {
        case "localhost", "127.0.0.1", "::1":
            return true
        default:
            return false
        }
    }
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var notice: UpdateNotice?
    @Published private(set) var status: UpdateStatus = .idle

    let currentVersion: String
    let buildIdentity: UpdateBuildIdentity
    @Published private(set) var selectedChannel: AppUpdateChannel
    private let preferences: UserDefaults
    private var pendingChannel: AppUpdateChannel?
    /// The saved mirror base, re-read from preferences after every change.
    @Published private(set) var customUpdateSourceBase: URL?
    private var pendingSourceChange: URL??
    var installedChannel: AppUpdateChannel { isPreview ? .autobuild : .stable }
    var needsChannelInstallation: Bool { selectedChannel.requiresFullInstallation(from: installedChannel) }
    var selectedReleaseURL: URL { selectedChannel.releaseURL(info: bundle.infoDictionary ?? [:]) }
    var canChangeChannel: Bool {
        !isBusy && !isInstalling && pendingChannel == nil && pendingSourceChange == nil
            && (updater?.sessionInProgress != true || userDriver?.hasPendingReply == true)
    }
    /// The official stable feed for this Mac, or nil for builds without one.
    var defaultStableFeed: URL? {
        AppUpdateChannel.stable.feedURL(info: bundle.infoDictionary ?? [:], architecture: Self.architecture)
            .flatMap(URL.init(string:))
    }
    /// AutoBuild always uses the official source, so the setting only applies
    /// to a stable build that stays on the stable channel.
    var canCustomizeUpdateSource: Bool { !isPreview && selectedChannel == .stable && defaultStableFeed != nil }
    /// The source updates use right now; the default when customizing is unavailable.
    var effectiveUpdateSource: AppUpdateSource? {
        defaultStableFeed.map {
            AppUpdateSource(defaultFeed: $0, customBase: canCustomizeUpdateSource ? customUpdateSourceBase : nil)
        }
    }
    var isPreview: Bool { buildIdentity.isPreview }
    var versionDescription: String {
        isPreview ? AutoBuildTimestamp.label(timestamp: buildIdentity.buildDate, build: buildIdentity.build) : currentVersion
    }
    let stableRollback: MacStableRollback
    private var rollbackObservation: AnyCancellable?
    private var rollbackRequested = false
    var canReturnToStable: Bool {
        isPreview && pendingChannel == nil && !isChecking && !isInstalling && !stableRollback.state.isActive && !rollbackRequested
            && (updater?.sessionInProgress != true || userDriver?.hasPendingReply == true)
    }
    var isBusy: Bool { stableRollback.state.isActive || rollbackRequested || isChecking || (isInstalling && status != .waitingForTermination) }
    var willRelaunchForUpdate: (() -> Void)?
    var didFinishUpdateCycle: (() -> Void)?
    /// Opens the Software Update window. A live scene installs it because only
    /// SwiftUI views can reach `openWindow`.
    var presentDetailsWindow: (() -> Void)?
    /// Set when a menu or button check should show the update it finds, so the
    /// person can install it without locating the title bar indicator.
    private var presentsFoundUpdate = false
    private let bundle: Bundle
    private var updater: SPUUpdater?
    private var userDriver: LitheSparkleUserDriver?
    @Published private(set) var updateInfo: UpdateInfo?
    private var started = false
    /// Sparkle downloads archives through this loopback relay so interrupted
    /// downloads resume and failures keep their network cause.
    private let downloadRelay: UpdateDownloadRelay?
    static let releasePageURL = AppUpdateChannel.stableReleaseURL

    init(bundle: Bundle = .main, preferences: UserDefaults = .standard,
         diagnosticSink: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
         sessionFactory: @escaping @Sendable (URLSessionConfiguration) -> MacNetworkSessionLease = {
             MacNetworkSessionProvider.makeSession(configuration: $0, plan: nil)
         },
         downloadRelay: UpdateDownloadRelay? = nil) {
        self.preferences = preferences
        selectedChannel = AppUpdateChannel.saved(in: preferences,
            defaultChannel: MacAppIdentity(bundleIdentifier: bundle.bundleIdentifier).isDevelopment ? .autobuild : .stable)
        // Only the rollback downloader goes through our own session. Sparkle and
        // its archive relay use the default configuration, which always follows
        // the system proxy.
        let storage = MacFileStorage(identity: MacAppIdentity(bundleIdentifier: bundle.bundleIdentifier))
        self.downloadRelay = downloadRelay ?? UpdateDownloadRelay(store: UpdateDownloadPartialStore(
            directory: storage.cacheDirectory().appendingPathComponent("Lithe/UpdateDownloads", isDirectory: true)),
            diagnosticSink: diagnosticSink)
        stableRollback = MacStableRollback(diagnosticSink: diagnosticSink, sessionFactory: sessionFactory)
        self.bundle = bundle
        buildIdentity = UpdateBuildIdentity(info: bundle.infoDictionary ?? [:])
        customUpdateSourceBase = AppUpdateChannel.stable.feedURL(info: bundle.infoDictionary ?? [:],
            architecture: Self.architecture).flatMap(URL.init(string:))
            .flatMap { AppUpdateSource.saved(in: preferences, defaultFeed: $0).customBase }
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        super.init()
        rollbackObservation = stableRollback.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if bundle.bundleURL.pathExtension == "app", let identifier = bundle.bundleIdentifier {
            let target = bundle.bundleURL
            DispatchQueue.global(qos: .utility).async {
                StableRollbackPackage.removeLeftoverStaging(beside: target, identifier: identifier)
            }
        }
    }

    /// The caller confirms the rolling-build warning before committing consent.
    @discardableResult
    func selectChannel(_ channel: AppUpdateChannel, acknowledgingRisk: Bool = false) -> Bool {
        guard canChangeChannel, channel != .autobuild || acknowledgingRisk else { return false }
        guard channel != selectedChannel else { return true }
        if let reply = userDriver?.takeReply() {
            // Sparkle must finish the old offer before its feed can change.
            pendingChannel = channel
            reply(.dismiss)
        } else {
            applyChannel(channel)
        }
        return true
    }

    /// Saves a mirror base, or the default when `base` is nil, after the caller
    /// tested it. A waiting offer from the old source is dismissed first.
    @discardableResult
    func applyUpdateSource(_ base: URL?) -> Bool {
        guard canChangeChannel, canCustomizeUpdateSource else { return false }
        if let reply = userDriver?.takeReply() {
            pendingSourceChange = .some(base)
            reply(.dismiss)
        } else {
            storeUpdateSource(base)
        }
        return true
    }

    private func storeUpdateSource(_ base: URL?) {
        if let base, base != defaultStableFeed?.deletingLastPathComponent() {
            preferences.set(base.absoluteString, forKey: AppUpdateSource.preferenceKey)
        } else {
            preferences.removeObject(forKey: AppUpdateSource.preferenceKey)
        }
        customUpdateSourceBase = defaultStableFeed.flatMap { AppUpdateSource.saved(in: preferences, defaultFeed: $0).customBase }
        updateInfo = nil
        notice = nil
        status = .idle
        updater?.resetUpdateCycle()
    }

    /// Fetches a candidate source's feed and newest archive without saving it.
    func testUpdateSource(_ base: URL) async -> UpdateSourceProbeResult {
        guard let defaultStableFeed else { return .failed(UpdateCheckError.invalidResponse.userMessage) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return await UpdateSourceProbe.run(AppUpdateSource(defaultFeed: defaultStableFeed, customBase: base), session: session)
    }

    private func applyChannel(_ channel: AppUpdateChannel) {
        selectedChannel = channel
        preferences.set(channel.rawValue, forKey: AppUpdateChannel.preferenceKey)
        updateInfo = nil
        notice = nil
        status = .idle
        updater?.resetUpdateCycle()
    }

    /// Starts an update check. `presentingDetails` opens the Software Update
    /// window when the manual check finds an update; Settings leaves it off
    /// because its install button sits next to the check button.
    func checkForUpdates(manual: Bool = false, presentingDetails: Bool = false) async {
        guard !stableRollback.state.isActive, !rollbackRequested, pendingChannel == nil else { return }
        if needsChannelInstallation {
            guard manual else { return }
            notice = UpdateNotice(title: L10n.string("Install the selected channel"),
                message: L10n.string("Changing channels requires a full installation and may install an older version. Open the selected release page to download its installer. Your channel selection is saved for future updates."),
                action: .open(selectedReleaseURL))
            return
        }
        // An offer that is still waiting for a choice is shown again rather
        // than starting another Sparkle session.
        if manual, presentingDetails, updateInfo != nil, userDriver?.hasPendingReply == true {
            presentDetails()
            return
        }
        // Local builds deliberately omit both values. Malformed or partial
        // configurations still surface an error instead of silently disabling updates.
        if !manual, bundle.object(forInfoDictionaryKey: "SUFeedURL") == nil,
           bundle.object(forInfoDictionaryKey: "SUPublicEDKey") == nil { return }
        do {
            if !started {
                try Self.validateConfiguration(bundle.infoDictionary ?? [:])
                let driver = LitheSparkleUserDriver(hostBundle: bundle, delegate: nil)
                driver.presentUpdate = { [weak self] item in self?.receiveOffer(item) }
                driver.installationWaiting = { [weak self] waiting in
                    self?.installationWaitingForTermination(waiting)
                }
                driver.downloadFailureMessage = { [weak self] error in
                    guard let self else { return nil }
                    if let failure = self.downloadFailure(for: error) {
                        return Self.downloadFailureMessage(failure, mirrorHost: self.mirrorHost)
                    }
                    return self.mirrorFeedFailureMessage(for: error)
                }
                driver.downloadProgress = { [weak self] progress in
                    guard let self, let info = self.updateInfo else { return }
                    self.status = .downloading(version: info.targetVersion, progress: progress)
                }
                let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
                self.userDriver = driver
                self.updater = updater
                try updater.start()
                started = true
            }
            // Sparkle owns automatic scheduling and persisted skip/check preferences.
            if manual, let updater, updater.canCheckForUpdates {
                presentsFoundUpdate = presentingDetails
                updater.checkForUpdates()
            }
        } catch {
            status = .failed(code: .installFailed, message: error.localizedDescription)
            if manual {
                notice = UpdateNotice(title: "Could not check for updates",
                    message: error.localizedDescription, action: .open(buildIdentity.releaseURL))
            }
        }
    }

    func installAvailableUpdate() async {
        guard !stableRollback.state.isActive, !rollbackRequested,
              pendingChannel == nil, !needsChannelInstallation else { return }
        if let reply = userDriver?.takeReply() { reply(.install) }
        else { await checkForUpdates(manual: true) }
    }

    /// Shows the offered update, with its release notes and install action.
    func presentDetails() {
        guard updateInfo != nil else { return }
        presentDetailsWindow?()
    }

    func remindLater() { userDriver?.takeReply()?(.dismiss) }
    func skipVersion() { userDriver?.takeReply()?(.skip) }
    func retryInstallation() async { await checkForUpdates(manual: true) }

    func returnToStable() {
        guard canReturnToStable else { return }
        if MacAppIdentity(bundleIdentifier: bundle.bundleIdentifier).isDevelopment {
            // Different applications coexist. Never replace Lithe-Dev with Lithe
            // or ask the legacy rollback installer to accept another bundle ID.
            openRelease(AppUpdateChannel.stable.releaseURL(info: bundle.infoDictionary ?? [:]))
            return
        }
        if let reply = userDriver?.takeReply() {
            pendingChannel = .stable
            rollbackRequested = true
            reply(.dismiss)
        } else if updater?.sessionInProgress != true {
            applyChannel(.stable)
            stableRollback.download(bundle: bundle)
        }
    }

    func installationWaitingForTermination(_ waiting: Bool) {
        isChecking = false
        isInstalling = true
        status = waiting ? .waitingForTermination : .installing(version: updateInfo?.targetVersion ?? currentVersion)
    }

    /// Records an update Sparkle offers and waits for the person's choice.
    /// Scheduled offers stay in the title bar; a manual check opens the window.
    func receiveOffer(_ item: SUAppcastItem) {
        guard pendingChannel == nil, !needsChannelInstallation else {
            userDriver?.takeReply()?(.dismiss)
            return
        }
        updateInfo = buildIdentity.updateInfo(version: currentVersion, targetVersion: item.displayVersionString,
            targetBuild: item.versionString, date: item.date, notes: item.itemDescription, infoURL: item.infoURL)
        status = .available(version: item.displayVersionString, url: item.infoURL ?? buildIdentity.releaseURL)
        if presentsFoundUpdate {
            presentsFoundUpdate = false
            presentDetails()
        }
    }

    func openRelease(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    static func validateConfiguration(_ info: [String: Any]) throws {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else {
            throw NSError(domain: "app.lithe.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    L10n.string("This build does not have a configured update feed and signing key. Download a published version from GitHub Releases.")])
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !needsChannelInstallation, pendingChannel == nil else {
            throw NSError(domain: "app.lithe.updates", code: 3,
                userInfo: [NSLocalizedDescriptionKey: L10n.string("Install the selected channel")])
        }
        guard !stableRollback.state.isActive, !rollbackRequested else {
            throw NSError(domain: "app.lithe.updates", code: 2,
                userInfo: [NSLocalizedDescriptionKey: L10n.string("A stable release installation is already in progress.")])
        }
        isChecking = true
        status = .checking
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        if canCustomizeUpdateSource, let source = effectiveUpdateSource { return source.feedURL.absoluteString }
        return selectedChannel.feedURL(info: bundle.infoDictionary ?? [:], architecture: Self.architecture)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isChecking = false
        status = .available(version: item.displayVersionString, url: item.infoURL ?? buildIdentity.releaseURL)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        isChecking = false
        status = .upToDate(version: currentVersion)
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool {
        !isPreview
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        isChecking = false
        isInstalling = true
        status = .downloading(version: item.displayVersionString, progress: .initial)
        guard let url = request.url else { return }
        let upstream = effectiveUpdateSource?.downloadURL(for: url) ?? url
        if let relayed = downloadRelay?.relayURL(for: upstream) { request.url = relayed } else { request.url = upstream }
    }

    /// The network cause of a failed archive download. The relay's record wins
    /// because Sparkle only observed the loopback connection.
    func downloadFailure(for error: Error) -> UpdateDownloadFailure? {
        let error = error as NSError
        guard error.domain == SUSparkleErrorDomain, error.code == Int(SUError.downloadError.rawValue) else { return nil }
        if let failure = downloadRelay?.lastFailure { return failure }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error,
              let host = (underlying as? URLError)?.failingURL?.host,
              !UpdateEndpointConfiguration.isLoopbackHost(host) else { return nil }
        return UpdateDownloadFailure(underlying)
    }

    /// A mirror's appcast could not be fetched. Sparkle's own wording does not
    /// say which server failed, which matters once the person picked one.
    func mirrorFeedFailureMessage(for error: Error) -> String? {
        let error = error as NSError
        guard let mirrorHost, error.domain == SUSparkleErrorDomain,
              error.code == Int(SUError.appcastError.rawValue) else { return nil }
        let failure = (error.userInfo[NSUnderlyingErrorKey] as? Error).flatMap(UpdateDownloadFailure.init)
            ?? .invalidResponse
        return failure.message(host: mirrorHost)
    }

    /// Failure messages name the mirror instead of GitHub when one is in use.
    private var mirrorHost: String? { effectiveUpdateSource.flatMap { $0.isCustom ? $0.host : nil } }

    static func downloadFailureMessage(_ failure: UpdateDownloadFailure, mirrorHost: String? = nil) -> String {
        failure.message(host: mirrorHost) + " "
            + L10n.string("Downloaded data was kept. Try again to resume from where it stopped.")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstalling = true
        status = .installing(version: item.displayVersionString)
        // Sparkle requests normal AppKit termination, preserving unsaved-document
        // confirmation and the application's bounded module cleanup.
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRelaunchForUpdate?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        defer {
            if let channel = pendingChannel {
                pendingChannel = nil
                applyChannel(channel)
            }
            if let base = pendingSourceChange {
                pendingSourceChange = nil
                storeUpdateSource(base)
            }
            if rollbackRequested {
                rollbackRequested = false
                stableRollback.download(bundle: bundle)
            }
        }
        didFinishUpdateCycle?()
        presentsFoundUpdate = false
        updateInfo = nil
        isChecking = false
        isInstalling = false
        if let error {
            let nsError = error as NSError
            if needsChannelInstallation || (nsError.domain == "app.lithe.updates" && nsError.code == 3) {
                status = .idle
            } else if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue {
                status = .upToDate(version: currentVersion)
            } else if nsError.domain == SUSparkleErrorDomain &&
                        [SUError.installationCanceledError.rawValue, SUError.installationAuthorizeLaterError.rawValue].contains(Int32(nsError.code)) {
                status = .idle
            } else if let failure = downloadFailure(for: error) {
                status = .failed(code: failure.checkError.code, message: Self.downloadFailureMessage(failure, mirrorHost: mirrorHost))
            } else {
                status = .failed(code: .installFailed, message: error.localizedDescription)
            }
        } else if case .upToDate = status {
            return
        } else {
            // Dismissal and cancellation must clear stale progress and install actions.
            status = .idle
        }
    }
}

@MainActor
final class LitheSparkleUserDriver: SPUStandardUserDriver {
    var presentUpdate: ((SUAppcastItem) -> Void)?
    var downloadProgress: ((UpdateDownloadProgress) -> Void)?
    var installationWaiting: ((Bool) -> Void)?
    /// Replaces Sparkle's generic download error with the observed cause.
    var downloadFailureMessage: ((Error) -> String?)?
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    var hasPendingReply: Bool { updateReply != nil }
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64?

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // Lithe already displays checking state. No separate checking window is needed.
    }

    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                      retryTerminatingApplication: @escaping () -> Void) {
        super.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication)
        // Keep Sparkle's retry callback and active installation intact. A manual
        // check brings its existing retry window into focus without downloading again.
        installationWaiting?(!applicationTerminated)
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard let message = downloadFailureMessage?(error) else {
            return super.showUpdaterError(error, acknowledgement: acknowledgement)
        }
        let original = error as NSError
        let specific = NSError(domain: original.domain, code: original.code, userInfo: [
            NSLocalizedDescriptionKey: message,
            NSUnderlyingErrorKey: original,
        ])
        super.showUpdaterError(specific, acknowledgement: acknowledgement)
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        receivedBytes = 0
        expectedBytes = nil
        downloadProgress?(.initial)
        super.showDownloadInitiated(cancellation: cancellation)
    }

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = Int64(clamping: expectedContentLength)
        downloadProgress?(UpdateDownloadProgress(downloadedBytes: receivedBytes, totalBytes: expectedBytes))
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += Int64(clamping: length)
        downloadProgress?(UpdateDownloadProgress(downloadedBytes: receivedBytes, totalBytes: expectedBytes))
        super.showDownloadDidReceiveData(ofLength: length)
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Keep scheduled offers in Lithe's non-modal update control. Sparkle owns
        // the subsequent download, authorization and installation windows.
        updateReply = reply
        presentUpdate?(appcastItem)
    }

    func takeReply() -> ((SPUUserUpdateChoice) -> Void)? {
        let reply = updateReply
        updateReply = nil
        return reply
    }

    override func dismissUpdateInstallation() {
        updateReply = nil
        super.dismissUpdateInstallation()
    }
}
