import AppKit
import CryptoKit
import Foundation

enum StableRollbackState: Equatable {
    case idle, downloading, preparing, cancelling, ready(String), requestingTermination, installing, failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }
}

@MainActor
final class MacStableRollback: ObservableObject {
    typealias PackageLoader = @Sendable (Bundle, @escaping @Sendable () async -> Void) async throws -> StableRollbackPackage
    @Published private(set) var state: StableRollbackState = .idle
    var requestTermination: (() -> Void)?
    private var task: Task<Void, Never>?
    private var staged: StableRollbackPackage?
    private var helper: Process?
    private let loadPackage: PackageLoader

    init(loadPackage: @escaping PackageLoader = { bundle, preparing in
        try await StableRollbackPackage.download(bundle: bundle, preparing: preparing)
    }) {
        self.loadPackage = loadPackage
    }

    func download(bundle: Bundle) {
        guard !state.isActive else { return }
        state = .downloading
        task = Task {
            do {
                if let staged {
                    // Never remove a recovery copy left by a previous installer.
                    if !FileManager.default.fileExists(atPath: staged.root.appendingPathComponent("previous.app").path) {
                        try await staged.discard()
                    }
                    self.staged = nil
                }
                let package = try await loadPackage(bundle) { [weak self] in
                    await self?.beginPreparation()
                }
                if Task.isCancelled {
                    try await package.discard()
                    throw CancellationError()
                }
                staged = package
                state = .ready(package.version)
            } catch {
                if error is CancellationError || (Task.isCancelled && (error as? URLError)?.code == .cancelled) { state = .idle }
                else { state = .failed((error as? UpdateCheckError)?.userMessage ?? error.localizedDescription) }
            }
            task = nil
        }
    }

    private func beginPreparation() {
        if state != .cancelling { state = .preparing }
    }

    func cancel() {
        guard state != .installing, state != .requestingTermination else { return }
        if let task { state = .cancelling; task.cancel(); return }
        state = .cancelling
        task = Task {
            do {
                if let staged { try await staged.discard() }
                staged = nil
                state = .idle
            } catch { state = .failed(error.localizedDescription) }
            task = nil
        }
    }

    func install() {
        guard case .ready = state, let requestTermination else { return }
        state = .requestingTermination
        requestTermination()
    }

    @discardableResult
    func terminationCancelled() -> Bool {
        guard state == .requestingTermination, let staged else { return false }
        state = .ready(staged.version)
        return true
    }

    // Called only after unsaved-document confirmation, immediately before the
    // application's bounded shutdown. A cancelled prompt never starts a helper.
    func prepareConfirmedTermination() -> Bool {
        guard state == .requestingTermination, let staged else { return true }
        do {
            let script = staged.root.appendingPathComponent("replace.sh")
            try StableRollbackPackage.replacementScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier),
                                 staged.root.path, staged.target.path]
            process.standardInput = FileHandle.nullDevice
            let log = staged.root.appendingPathComponent("installation.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.helper = nil
                    self.state = .failed(String(localized: "The stable installer stopped. Your current app has been preserved. Try again or download the stable release manually."))
                }
            }
            try process.run()
            helper = process
            state = .installing
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

}

enum StableRollbackFailure: LocalizedError {
    case cannotReplace, invalidBundle, invalidPublisherSignature
    var errorDescription: String? {
        switch self {
        case .invalidPublisherSignature:
            return String(localized: "The stable release is missing a valid publisher signature. Nothing was installed. Try a newer release or install manually from a trusted source.")
        case .cannotReplace:
            return String(localized: "Lithe cannot replace this app in its current folder. Move it to a writable Applications folder or install the stable release manually.")
        case .invalidBundle:
            return String(localized: "The downloaded app does not match the selected stable release. Nothing was installed.")
        }
    }
}

struct StableRollbackPackage: Sendable {
    let root: URL
    let target: URL
    let version: String

    static func download(bundle: Bundle, preparing: @escaping @Sendable () async -> Void) async throws -> Self {
        let target = bundle.bundleURL.resolvingSymlinksInPath()
        guard target.pathExtension == "app", let identifier = bundle.bundleIdentifier,
              let architecture = UpdateArchitecture.current else { throw UpdateCheckError.notAppBundle }
        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32 else { throw StableRollbackFailure.invalidPublisherSignature }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw StableRollbackFailure.cannotReplace
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: UpdateEndpointConfiguration.productionManifestURL)
        try validateResponse(response)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data).validated()
        let asset = try manifest.asset(for: architecture)
        guard let signature = asset.edSignature, Data(base64Encoded: signature)?.count == 64 else {
            throw StableRollbackFailure.invalidPublisherSignature
        }
        let (download, archiveResponse) = try await session.download(from: asset.url)
        defer { try? FileManager.default.removeItem(at: download) }
        try validateResponse(archiveResponse)
        try Task.checkCancellation()
        await preparing()
        return try await prepare(download: download, asset: asset, version: manifest.version,
            target: target, identifier: identifier, architecture: architecture, publicKey: publicKey)
    }

    private static func validateResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        if response.statusCode == 404 { throw UpdateCheckError.noPublishedRelease }
        guard (200..<300).contains(response.statusCode) else { throw UpdateCheckError.httpStatus(response.statusCode) }
    }

    func discard() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try FileManager.default.removeItem(at: root) })
            }
        }
    }

    nonisolated static func prepare(download: URL, asset: UpdateManifestAsset, version: String,
                                   target: URL, identifier: String, architecture: UpdateArchitecture, publicKey: String) async throws -> Self {
        // Native filesystem and process work is bounded, but blocking; keep it
        // off both the UI thread and Swift's cooperative executor.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try prepareSynchronously(download: download, asset: asset, version: version,
                        target: target, identifier: identifier, architecture: architecture, publicKey: publicKey)
                })
            }
        }
    }

    private static func prepareSynchronously(download: URL, asset: UpdateManifestAsset, version: String,
                                            target: URL, identifier: String, architecture: UpdateArchitecture, publicKey: String) throws -> Self {
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.normalizedSHA256 else { throw UpdateCheckError.checksumMismatch }
        // The manifest checksum is not proof of publisher identity. Only the
        // key embedded in the installed app is trusted, never downloaded key data.
        guard let keyData = Data(base64Encoded: publicKey),
              let signature = asset.edSignature.flatMap({ Data(base64Encoded: $0) }),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: data) else { throw StableRollbackFailure.invalidPublisherSignature }
        let manager = FileManager.default
        // Stage on the target volume so both rename operations remain atomic.
        let root = target.deletingLastPathComponent().appendingPathComponent(".lithe-stable-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        let mount = root.appendingPathComponent("mount")
        var mounted = false
        defer {
            if mounted {
                do {
                    try run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                    mounted = false
                } catch { NSLog("Stable rollback disk image cleanup failed: %@", error.localizedDescription) }
            }
            // Never recurse through a mount that macOS refused to detach.
            if !succeeded && !mounted {
                do { try manager.removeItem(at: root) }
                catch { NSLog("Stable rollback staging cleanup failed: %@", error.localizedDescription) }
            }
        }
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", ["attach", download.path, "-readonly", "-nobrowse", "-mountpoint", mount.path])
        mounted = true
        let source = mount.appendingPathComponent("Lithe.app")
        let destination = root.appendingPathComponent("new.app")
        try run("/usr/bin/ditto", [source.path, destination.path])
        try run("/usr/bin/hdiutil", ["detach", mount.path])
        mounted = false
        let infoURL = destination.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any] ?? [:]
        try validateBundle(info, identifier: identifier, version: version)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
        try run("/usr/bin/lipo", [destination.appendingPathComponent("Contents/MacOS/Lithe").path, "-verify_arch", architecture.rawValue])
        succeeded = true
        return Self(root: root, target: target, version: version)
    }

    static func validateBundle(_ info: [String: Any], identifier: String, version: String) throws {
        guard info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleShortVersionString"] as? String == version,
              info["CFBundleExecutable"] as? String == "Lithe",
              [nil, "stable"].contains(info["LitheUpdateChannel"] as? String) else { throw StableRollbackFailure.invalidBundle }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard !UpdateVersion.isNewer(minimum, than: current) else { throw StableRollbackFailure.invalidBundle }
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let result = MacProcessRunner().run(ProcessRequest(executablePath: executable,
            arguments: arguments, timeoutMilliseconds: 120_000))
        guard result.succeeded else {
            NSLog("%@", preparationDiagnostic(executable: executable, arguments: arguments,
                exitCode: result.exitCode, output: result.output))
            throw UpdateCheckError.toolFailed(executable)
        }
    }

    static func preparationDiagnostic(executable: String, arguments: [String], exitCode: Int32, output: String) -> String {
        var sanitized = output
        let paths = arguments.filter { $0.hasPrefix("/") }.flatMap {
            [$0, URL(fileURLWithPath: $0).deletingLastPathComponent().path]
        } + [NSHomeDirectory(), NSTemporaryDirectory()]
        for path in Set(paths).filter({ $0 != "/" }).sorted(by: { $0.count > $1.count }) {
            sanitized = sanitized.replacingOccurrences(of: path, with: "<path>")
        }
        sanitized = sanitized.replacingOccurrences(of: #"/[^\s\"'<>]+"#, with: "<path>", options: .regularExpression)
        let stage = URL(fileURLWithPath: executable).lastPathComponent
        return "Stable rollback preparation stage=\(stage) exit=\(exitCode): \(sanitized.prefix(2048))"
    }

    static let replacementScript = #"""
    #!/bin/sh
    set -eu
    app_pid="$1"
    root="$2"
    target="$3"
    opener="${4:-/usr/bin/open}"
    limit="${5:-600}"
    attempts=0
    while /bin/kill -0 "$app_pid" 2>/dev/null; do
        # Never force-kill an app whose shutdown did not finish.
        [ "$attempts" -lt "$limit" ] || exit 1
        /bin/sleep 0.2
        attempts=$((attempts + 1))
    done
    [ -d "$root/new.app" ] && [ -d "$target" ] && [ ! -e "$root/previous.app" ] || exit 1
    /bin/mv "$target" "$root/previous.app"
    if ! /bin/mv "$root/new.app" "$target"; then
        /bin/mv "$root/previous.app" "$target"
        "$opener" "$target" || true
        exit 1
    fi
    if ! "$opener" "$target"; then
        /bin/mv "$target" "$root/new.app"
        /bin/mv "$root/previous.app" "$target"
        "$opener" "$target" || true
        exit 1
    fi
    # Retain previous.app and the log for recovery; user data is never removed.
    """#
}
