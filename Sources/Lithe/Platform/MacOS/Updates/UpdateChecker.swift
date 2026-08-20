import AppKit
import CryptoKit
import Foundation

struct UpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: UpdateNoticeAction
}

struct UpdatePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let releaseURL: URL
}

enum UpdateNoticeAction {
    case install
    case open(URL)
    case dismiss
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
    case noRelease
    case failed(message: String)
}

struct UpdateEndpointConfiguration: Equatable {
    static let productionManifestURL = URL(
        string: "https://github.com/1lck/Lithe-IDEA/releases/latest/download/latest.json"
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
final class UpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var notice: UpdateNotice?
    @Published private(set) var updatePrompt: UpdatePrompt?
    @Published private(set) var status: UpdateStatus = .idle

    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    private static let lastAutomaticCheckKey = "lithe.update.lastAutomaticCheck"
    private static let releasePageURL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!

    let currentVersion: String
    var isBusy: Bool { isChecking || isInstalling }

    private let transport: any UpdateNetworkTransport
    private let preferences: UserDefaults
    private let now: () -> Date
    private let architecture: UpdateArchitecture?
    private let endpoint: UpdateEndpointConfiguration
    private var availableManifest: UpdateManifest?
    private var availableAsset: UpdateManifestAsset?

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        transport = MacUpdateNetworkTransport()
        preferences = .standard
        now = Date.init
        architecture = .current
        endpoint = .production
    }

    init(
        currentVersion: String,
        transport: any UpdateNetworkTransport,
        preferences: UserDefaults,
        now: @escaping () -> Date = Date.init,
        architecture: UpdateArchitecture? = .current,
        endpoint: UpdateEndpointConfiguration = .production
    ) {
        self.currentVersion = currentVersion
        self.transport = transport
        self.preferences = preferences
        self.now = now
        self.architecture = architecture
        self.endpoint = endpoint
    }

    func checkForUpdates(manual: Bool = false) async {
        guard !isBusy else { return }
        if !manual, !shouldPerformAutomaticCheck() { return }

        isChecking = true
        status = .checking
        availableManifest = nil
        availableAsset = nil
        updatePrompt = nil
        if manual { notice = nil }
        defer { isChecking = false }

        do {
            let manifest = try await fetchLatestManifest()
            guard let architecture else { throw UpdateCheckError.noCompatibleAsset }
            let asset = try manifest.asset(for: architecture)

            if !manual {
                preferences.set(now(), forKey: Self.lastAutomaticCheckKey)
            }

            if UpdateVersion.isNewer(manifest.version, than: currentVersion) {
                availableManifest = manifest
                availableAsset = asset
                status = .available(version: manifest.version, url: manifest.releaseURL)
                updatePrompt = UpdatePrompt(
                    title: "Lithe \(manifest.version) is available",
                    message: "Lithe will download the update and restart after replacing the current app.",
                    releaseURL: manifest.releaseURL
                )
            } else if manual {
                status = .upToDate(version: currentVersion)
                notice = UpdateNotice(
                    title: "Lithe is up to date",
                    message: "You are using the latest published version, Lithe \(currentVersion).",
                    action: .dismiss
                )
            } else {
                status = .upToDate(version: currentVersion)
            }
        } catch UpdateCheckError.noPublishedRelease {
            status = .noRelease
            if manual {
                notice = UpdateNotice(
                    title: "No release is available yet",
                    message: "There is no published GitHub Release to check yet.",
                    action: .open(Self.releasePageURL)
                )
            }
        } catch {
            let updateError = normalizedError(error)
            status = .failed(message: updateError.userMessage)
            if manual {
                notice = UpdateNotice(
                    title: "Could not check for updates",
                    message: updateError.userMessage,
                    action: .open(Self.releasePageURL)
                )
            }
        }
    }

    func installAvailableUpdate() async {
        guard !isBusy,
              let manifest = availableManifest,
              let asset = availableAsset,
              case .available(let version, _) = status else { return }

        isInstalling = true
        status = .downloading(version: version, progress: .initial)
        updatePrompt = nil
        notice = nil
        defer { isInstalling = false }

        do {
            var request = URLRequest(url: asset.url)
            request.setValue("Lithe/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let updateChecker = self
            let downloadedURL = try await transport.download(
                request,
                progress: { progress in
                    await MainActor.run {
                        updateChecker.status = .downloading(version: version, progress: progress)
                    }
                }
            )
            defer { try? FileManager.default.removeItem(at: downloadedURL) }

            try verify(downloadedFile: downloadedURL, against: asset)
            status = .installing(version: version)
            try scheduleReplacement(with: downloadedURL, version: version)
        } catch {
            let updateError = normalizedError(error, fallback: .downloadFailed)
            status = .failed(message: updateError.userMessage)
            notice = UpdateNotice(
                title: "Could not install update",
                message: updateError.userMessage,
                action: .open(manifest.releaseURL)
            )
        }
    }

    func openRelease(_ url: URL?) {
        guard let url else { return }
        notice = nil
        updatePrompt = nil
        NSWorkspace.shared.open(url)
    }

    func dismissUpdatePrompt() {
        updatePrompt = nil
    }

    private func fetchLatestManifest() async throws -> UpdateManifest {
        var request = URLRequest(url: endpoint.manifestURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lithe/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let response = try await transport.fetch(request)
        if response.statusCode == 404 {
            throw UpdateCheckError.noPublishedRelease
        }
        if response.statusCode == 403, isRateLimited(response) {
            throw UpdateCheckError.rateLimited
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateCheckError.httpStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: response.body)
                .validated(allowingLocalHTTP: endpoint.allowsLocalHTTP)
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.invalidManifest
        }
    }

    private func isRateLimited(_ response: UpdateHTTPResponse) -> Bool {
        if response.header(named: "X-RateLimit-Remaining") == "0" {
            return true
        }
        let body = String(data: response.body, encoding: .utf8)?.lowercased() ?? ""
        return body.contains("rate limit")
    }

    private func verify(downloadedFile: URL, against asset: UpdateManifestAsset) throws {
        let data = try Data(contentsOf: downloadedFile, options: .mappedIfSafe)
        let actualDigest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actualDigest == asset.normalizedSHA256 else {
            throw UpdateCheckError.checksumMismatch
        }
    }

    private func scheduleReplacement(with downloadedFile: URL, version: String) throws {
        let fileManager = FileManager.default
        let currentAppURL = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard currentAppURL.pathExtension == "app" else {
            throw UpdateCheckError.notAppBundle
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-update-\(UUID().uuidString)", isDirectory: true)
        let mountPoint = temporaryRoot.appendingPathComponent("mount", isDirectory: true)
        let stagedAppURL = temporaryRoot.appendingPathComponent("Lithe-\(version).app", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        var mounted = false
        var helperScheduled = false
        defer {
            if mounted && !helperScheduled {
                try? runProcess(
                    "/usr/bin/hdiutil",
                    arguments: ["detach", mountPoint.path, "-force"]
                )
            }
            if !helperScheduled {
                try? fileManager.removeItem(at: temporaryRoot)
            }
        }

        try runProcess(
            "/usr/bin/hdiutil",
            arguments: [
                "attach",
                downloadedFile.path,
                "-nobrowse",
                "-readonly",
                "-mountpoint",
                mountPoint.path
            ]
        )
        mounted = true

        let sourceAppURL = mountPoint.appendingPathComponent("Lithe.app", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceAppURL.path) else {
            throw UpdateCheckError.appNotFoundInDiskImage
        }
        try fileManager.copyItem(at: sourceAppURL, to: stagedAppURL)
        try launchReplacementHelper(
            stagedAppURL: stagedAppURL,
            currentAppURL: currentAppURL,
            mountPoint: mountPoint,
            temporaryRoot: temporaryRoot
        )
        helperScheduled = true
    }

    private func launchReplacementHelper(
        stagedAppURL: URL,
        currentAppURL: URL,
        mountPoint: URL,
        temporaryRoot: URL
    ) throws {
        let helperURL = temporaryRoot.appendingPathComponent("install-update.sh")
        let helperScript = #"""
        #!/bin/sh
        set -eu

        app_pid="$1"
        staged_app="$2"
        target_app="$3"
        mount_point="$4"
        temporary_root="$5"
        old_app="${target_app}.lithe-old"

        install_without_privileges() {
            while /bin/kill -0 "$app_pid" 2>/dev/null; do
                /bin/sleep 0.2
            done
            /bin/sleep 0.5
            /bin/rm -rf "$old_app"
            /bin/mv "$target_app" "$old_app"
            if ! /bin/mv "$staged_app" "$target_app"; then
                /bin/mv "$old_app" "$target_app" || true
                exit 1
            fi
            /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
            /usr/bin/open "$target_app" >/dev/null 2>&1 || true
            /bin/sleep 2
            /bin/rm -rf "$old_app" "$temporary_root"
        }

        if [ -w "$(/usr/bin/dirname "$target_app")" ]; then
            install_without_privileges
        else
            /usr/bin/osascript - "$app_pid" "$staged_app" "$target_app" "$mount_point" "$temporary_root" <<'APPLESCRIPT'
        on run argv
            set appPID to item 1 of argv
            set stagedApp to item 2 of argv
            set targetApp to item 3 of argv
            set mountPoint to item 4 of argv
            set temporaryRoot to item 5 of argv
            set oldApp to targetApp & ".lithe-old"
            set installScript to "/bin/sh -c " & quoted form of ("while /bin/kill -0 " & quoted form of appPID & " 2>/dev/null; do /bin/sleep 0.2; done; /bin/sleep 0.5; /bin/rm -rf " & quoted form of oldApp & "; if ! /bin/mv " & quoted form of targetApp & " " & quoted form of oldApp & "; then exit 1; fi; if ! /bin/mv " & quoted form of stagedApp & " " & quoted form of targetApp & "; then /bin/mv " & quoted form of oldApp & " " & quoted form of targetApp & " || true; exit 1; fi; /usr/bin/hdiutil detach " & quoted form of mountPoint & " -force >/dev/null 2>&1 || true; /bin/rm -rf " & quoted form of oldApp & " " & quoted form of temporaryRoot)
            try
                do shell script installScript with administrator privileges
            on error
                do shell script "/usr/bin/hdiutil detach " & quoted form of mountPoint & " -force >/dev/null 2>&1 || true"
                error number -128
            end try
        end run
        APPLESCRIPT
            /usr/bin/open "$target_app" >/dev/null 2>&1 || true
        fi
        """#

        try helperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            helperURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            stagedAppURL.path,
            currentAppURL.path,
            mountPoint.path,
            temporaryRoot.path
        ]
        try helper.run()
        NSApp.terminate(nil)
    }

    private func runProcess(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateCheckError.toolFailed(executablePath)
        }
    }

    private func shouldPerformAutomaticCheck() -> Bool {
        guard let lastCheck = preferences.object(forKey: Self.lastAutomaticCheckKey) as? Date else {
            return true
        }
        return now().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval
    }

    private func normalizedError(
        _ error: Error,
        fallback: UpdateCheckError = .connectionFailed
    ) -> UpdateCheckError {
        if let updateError = error as? UpdateCheckError {
            return updateError
        }
        if error is UpdateTransportError {
            return .invalidResponse
        }
        guard let urlError = error as? URLError else {
            return fallback
        }

        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .tlsOrProxyFailure
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .dataNotAllowed:
            return .connectionFailed
        default:
            return fallback
        }
    }
}
