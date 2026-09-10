import AppKit
import Sparkle
import Foundation

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
}

struct UpdateBuildIdentity: Equatable {
    let isPreview: Bool
    let build: String
    let buildDate: String?
    let releaseURL: URL

    init(info: [String: Any]) {
        isPreview = info["LitheUpdateChannel"] as? String == "preview"
        build = info["CFBundleVersion"] as? String ?? "0"
        buildDate = info["LitheBuildTimestamp"] as? String
        releaseURL = (info["LitheUpdateReleaseURL"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!
    }

    func updateInfo(version: String, targetVersion: String, targetBuild: String,
                    date: Date?, notes: String?) -> UpdateInfo {
        UpdateInfo(currentVersion: version, targetVersion: targetVersion,
            releaseDate: date.map { ISO8601DateFormatter().string(from: $0) },
            releaseNotes: isPreview ? nil : notes, releaseURL: releaseURL,
            isPreview: isPreview, currentBuild: build, targetBuild: targetBuild)
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
    var isPreview: Bool { buildIdentity.isPreview }
    var versionDescription: String {
        isPreview ? "\(currentVersion) Preview (\(buildIdentity.build))" : currentVersion
    }
    var isBusy: Bool { isChecking || isInstalling }
    var willRelaunchForUpdate: (() -> Void)?
    var didFinishUpdateCycle: (() -> Void)?
    private let bundle: Bundle
    private var updater: SPUUpdater?
    private var userDriver: LitheSparkleUserDriver?
    @Published private(set) var updateInfo: UpdateInfo?
    private var started = false
    static let releasePageURL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        buildIdentity = UpdateBuildIdentity(info: bundle.infoDictionary ?? [:])
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        super.init()
    }

    func checkForUpdates(manual: Bool = false) async {
        do {
            if !started {
                try Self.validateConfiguration(bundle.infoDictionary ?? [:])
                let driver = LitheSparkleUserDriver(hostBundle: bundle, delegate: nil)
                driver.presentUpdate = { [weak self] item in self?.present(item) }
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
        if let reply = userDriver?.takeReply() { reply(.install) }
        else { await checkForUpdates(manual: true) }
    }

    func remindLater() { userDriver?.takeReply()?(.dismiss) }
    func skipVersion() { userDriver?.takeReply()?(.skip) }
    func retryInstallation() async { await checkForUpdates(manual: true) }

    private func present(_ item: SUAppcastItem) {
        updateInfo = buildIdentity.updateInfo(version: currentVersion, targetVersion: item.displayVersionString,
            targetBuild: item.versionString, date: item.date, notes: item.itemDescription)
        status = .available(version: item.displayVersionString, url: buildIdentity.releaseURL)
    }

    func openRelease(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    static func validateConfiguration(_ info: [String: Any]) throws {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else {
            throw NSError(domain: "app.lithe.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "This build does not have a configured update feed and signing key. Download a published version from GitHub Releases."])
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        isChecking = true
        status = .checking
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // The installed build owns its channel. Do not inherit a persisted feed
        // override when the user manually installs another distribution.
        bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isChecking = false
        status = .available(version: item.displayVersionString, url: buildIdentity.releaseURL)
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
        didFinishUpdateCycle?()
        updateInfo = nil
        isChecking = false
        isInstalling = false
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue {
                status = .upToDate(version: currentVersion)
            } else if nsError.domain == SUSparkleErrorDomain &&
                        [SUError.installationCanceledError.rawValue, SUError.installationAuthorizeLaterError.rawValue].contains(Int32(nsError.code)) {
                status = .idle
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
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64?

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // Lithe already displays checking state. No separate checking window is needed.
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
