import AppKit
import CryptoKit
import Foundation

struct GitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL
    let name: String?
    let prerelease: Bool
    let draft: Bool
    let assets: [GitHubReleaseAsset]

    var displayVersion: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case prerelease
        case draft
        case assets
    }
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: UpdateNoticeAction
}

enum UpdateNoticeAction {
    case install
    case open(URL)
    case dismiss
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String, url: URL)
    case downloading(version: String)
    case installing(version: String)
    case upToDate(version: String)
    case noRelease
    case failed
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var notice: UpdateNotice?
    @Published private(set) var status: UpdateStatus = .idle

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/1lck/Lithe-IDEA/releases/latest")!
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    private static let lastAutomaticCheckKey = "lithe.update.lastAutomaticCheck"

    let currentVersion: String
    var isBusy: Bool { isChecking || isInstalling }

    private var latestRelease: GitHubRelease?

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdates(manual: Bool = false) async {
        guard !isBusy else { return }
        if !manual, !shouldPerformAutomaticCheck() { return }

        isChecking = true
        status = .checking
        latestRelease = nil
        if manual { notice = nil }
        defer { isChecking = false }

        if !manual {
            UserDefaults.standard.set(Date(), forKey: Self.lastAutomaticCheckKey)
        }

        do {
            let release = try await fetchLatestRelease()
            guard !release.draft, !release.prerelease else {
                status = .noRelease
                return
            }

            if isNewer(release.displayVersion, than: currentVersion) {
                latestRelease = release
                status = .available(version: release.displayVersion, url: release.htmlURL)
                notice = UpdateNotice(
                    title: "Lithe \(release.displayVersion) is available",
                    message: "Lithe will download the update and restart after replacing the current app.",
                    action: .install
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
            status = .failed
            if manual {
                notice = UpdateNotice(
                    title: "Could not check for updates",
                    message: "Check your internet connection and try again later.",
                    action: .dismiss
                )
            }
        }
    }

    func installAvailableUpdate() async {
        guard !isBusy,
              let release = latestRelease,
              case .available(let version, _) = status else { return }

        isInstalling = true
        status = .downloading(version: version)
        notice = nil
        defer { isInstalling = false }

        do {
            let asset = try updateAsset(for: release)
            let downloadedURL: URL
            do {
                (downloadedURL, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            } catch {
                throw UpdateCheckError.downloadFailed
            }

            try verify(downloadedFile: downloadedURL, against: asset)
            status = .installing(version: version)
            try scheduleReplacement(with: downloadedURL, version: version)
        } catch {
            status = .failed
            notice = UpdateNotice(
                title: "Could not install update",
                message: userMessage(for: error),
                action: .dismiss
            )
        }
    }

    func openRelease(_ url: URL?) {
        guard let url else { return }
        notice = nil
        NSWorkspace.shared.open(url)
    }

    private static let releasePageURL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lithe/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            throw UpdateCheckError.noPublishedRelease
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func updateAsset(for release: GitHubRelease) throws -> GitHubReleaseAsset {
        let version = release.displayVersion
        let architectureAssetName = "Lithe-\(version)-\(currentArchitecture).dmg"
        let universalAssetName = "Lithe-\(version).dmg"

        if let asset = release.assets.first(where: { $0.name == architectureAssetName }) {
            return asset
        }
        if let asset = release.assets.first(where: { $0.name == universalAssetName }) {
            return asset
        }
        throw UpdateCheckError.noCompatibleAsset
    }

    private func verify(downloadedFile: URL, against asset: GitHubReleaseAsset) throws {
        guard let rawDigest = asset.digest else {
            throw UpdateCheckError.missingChecksum
        }

        let expectedDigest = rawDigest
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "sha256:", with: "")
            .lowercased()
        let data = try Data(contentsOf: downloadedFile, options: .mappedIfSafe)
        let actualDigest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actualDigest == expectedDigest else {
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

    private var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func userMessage(for error: Error) -> String {
        guard let updateError = error as? UpdateCheckError else {
            return "The update could not be installed. Download the release manually and try again."
        }
        return updateError.userMessage
    }

    private func shouldPerformAutomaticCheck() -> Bool {
        guard let lastCheck = UserDefaults.standard.object(forKey: Self.lastAutomaticCheckKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = versionComponents(candidate),
              let currentComponents = versionComponents(current) else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    private func versionComponents(_ version: String) -> [Int]? {
        let normalized = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let components = normalized.split(separator: ".", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }

        var values: [Int] = []
        for component in components {
            guard let value = Int(component) else { return nil }
            values.append(value)
        }
        return values
    }
}

private enum UpdateCheckError: Error {
    case noPublishedRelease
    case invalidResponse
    case httpStatus(Int)
    case noCompatibleAsset
    case missingChecksum
    case checksumMismatch
    case downloadFailed
    case notAppBundle
    case appNotFoundInDiskImage
    case toolFailed(String)

    var userMessage: String {
        switch self {
        case .noCompatibleAsset:
            return "No update package is available for this Mac. Download the release manually."
        case .missingChecksum:
            return "The update package has no checksum and cannot be verified."
        case .checksumMismatch:
            return "The downloaded update failed its checksum verification."
        case .downloadFailed:
            return "The update package could not be downloaded. Check your internet connection and try again."
        case .notAppBundle:
            return "Self-update is only available when Lithe is running from a packaged Lithe.app."
        case .appNotFoundInDiskImage:
            return "The downloaded disk image does not contain Lithe.app."
        case .toolFailed:
            return "macOS could not prepare the update disk image. Download the release manually and try again."
        case .noPublishedRelease, .invalidResponse, .httpStatus:
            return "The update could not be installed. Download the release manually and try again."
        }
    }
}
