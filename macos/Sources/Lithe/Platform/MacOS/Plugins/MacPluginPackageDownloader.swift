import Darwin
import Foundation
import LitheModuleAPI

struct MacDownloadedPluginPackage {
    let packageURL: URL
    let temporaryDirectory: URL
}

protocol MacPluginPackageDownloading {
    func download(
        pluginID: PluginID,
        hostVersion: PluginVersion
    ) async throws -> MacDownloadedPluginPackage
}

enum MacPluginPackageDownloadError: Error, Equatable, LocalizedError {
    case unsupportedPlugin(PluginID)
    case invalidEndpoint
    case httpStatus(Int)
    case invalidArchive
    case invalidLanguageServerPackage(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlugin(let pluginID):
            return "Online download is not available for plugin \(pluginID)."
        case .invalidEndpoint:
            return "The official plugin download endpoint is invalid."
        case .httpStatus(let status):
            return "The official plugin server returned HTTP \(status)."
        case .invalidArchive:
            return "The downloaded plugin archive does not contain a valid plugin package."
        case .invalidLanguageServerPackage(let detail):
            return "The downloaded PHP plugin does not contain a valid language-server package: \(detail)"
        case .extractionFailed(let detail):
            return "The downloaded plugin archive could not be extracted: \(detail)"
        }
    }
}

struct MacPluginDistributionConfiguration: Equatable, Sendable {
    enum Channel: String, Sendable {
        case stable
        case preview
    }

    let releaseBaseURL: URL
    let channel: Channel
    let architecture: String
    let releaseVersion: PluginVersion

    init(
        releaseBaseURL: URL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/download")!,
        channel: Channel = MacPluginDistributionConfiguration.defaultChannel,
        architecture: String = MacPluginDistributionConfiguration.currentArchitecture,
        releaseVersion: PluginVersion = MacPluginDistributionConfiguration.defaultReleaseVersion
    ) {
        self.releaseBaseURL = releaseBaseURL
        self.channel = channel
        self.architecture = architecture
        self.releaseVersion = releaseVersion
    }

    static let currentArchitecture: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()

    static let defaultChannel: Channel = {
        let value = Bundle.main.object(forInfoDictionaryKey: "LitheUpdateChannel") as? String
        return value == Channel.preview.rawValue ? .preview : .stable
    }()

    static let defaultReleaseVersion: PluginVersion = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = PluginVersion(value) else {
            return BuiltInPluginCatalog.hostVersion
        }
        return version
    }()

    func archiveURL(pluginID: PluginID) throws -> URL {
        guard pluginID == OfficialPluginCatalog.phpPluginID,
              architecture == "arm64" || architecture == "x86_64" else {
            throw MacPluginPackageDownloadError.unsupportedPlugin(pluginID)
        }
        let releaseTag = channel == .preview ? "preview-\(releaseVersion)" : "v\(releaseVersion)"
        let archiveName = "Lithe-PHP-Support-\(releaseVersion)-\(architecture).zip"
        guard releaseBaseURL.scheme?.lowercased() == "https",
              releaseBaseURL.host != nil else {
            throw MacPluginPackageDownloadError.invalidEndpoint
        }
        return releaseBaseURL
            .appendingPathComponent(releaseTag, isDirectory: true)
            .appendingPathComponent(archiveName, isDirectory: false)
    }
}

final class MacPluginPackageDownloader: MacPluginPackageDownloading {
    private static let extractionTimeout: TimeInterval = 5 * 60
    private static let extractionPollInterval: TimeInterval = 0.05
    private let configuration: MacPluginDistributionConfiguration
    private let session: URLSession
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        configuration: MacPluginDistributionConfiguration = MacPluginDistributionConfiguration(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.configuration = configuration
        self.session = session
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func download(
        pluginID: PluginID,
        hostVersion _: PluginVersion
    ) async throws -> MacDownloadedPluginPackage {
        let archiveURL = try configuration.archiveURL(pluginID: pluginID)
        try Task.checkCancellation()
        let request = URLRequest(url: archiveURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let (archiveURLOnDisk, response): (URL, URLResponse)
        do {
            (archiveURLOnDisk, response) = try await session.download(for: request)
        } catch {
            throw error
        }
        defer { try? fileManager.removeItem(at: archiveURLOnDisk) }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MacPluginPackageDownloadError.httpStatus(status)
        }
        try Task.checkCancellation()

        let extractionRoot = temporaryDirectory
            .appendingPathComponent("lithe-plugin-download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        do {
            try extract(archiveURLOnDisk, into: extractionRoot)
            let packageURL = try findPackage(in: extractionRoot, pluginID: pluginID)
            do {
                let manifest = try JSONDecoder().decode(
                    PluginManifest.self,
                    from: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
                )
                try MacPluginLanguageServerPackageValidator.validate(
                    packageAt: packageURL,
                    pluginManifest: manifest
                )
            } catch let error as MacPluginLanguageServerPackageValidationError {
                throw MacPluginPackageDownloadError.invalidLanguageServerPackage(
                    error.localizedDescription
                )
            } catch {
                throw MacPluginPackageDownloadError.invalidLanguageServerPackage(
                    "plugin.json could not be decoded"
                )
            }
            return MacDownloadedPluginPackage(
                packageURL: packageURL,
                temporaryDirectory: extractionRoot
            )
        } catch {
            try? fileManager.removeItem(at: extractionRoot)
            throw error
        }
    }

    private func extract(_ archiveURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw MacPluginPackageDownloadError.extractionFailed(error.localizedDescription)
        }
        // `ditto` is an external process, so waiting without a local deadline
        // would leave a cancelled or wedged download task alive indefinitely.
        // Poll on a bounded interval and terminate the process before
        // propagating cancellation or timeout to the caller.
        let deadline = Date().addingTimeInterval(Self.extractionTimeout)
        while process.isRunning {
            do {
                try Task.checkCancellation()
            } catch {
                terminateExtractionProcess(process)
                throw error
            }
            guard Date() < deadline else {
                terminateExtractionProcess(process)
                throw MacPluginPackageDownloadError.extractionFailed(
                    "ditto did not finish within \(Int(Self.extractionTimeout)) seconds"
                )
            }
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacPluginPackageDownloadError.extractionFailed(detail ?? "ditto exited with status \(process.terminationStatus)")
        }
    }

    private func terminateExtractionProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        if process.isRunning {
            process.interrupt()
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func findPackage(in root: URL, pluginID: PluginID) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "plugin.json",
                  let isDirectory = try? candidate.deletingLastPathComponent()
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else { continue }
            let packageURL = candidate.deletingLastPathComponent().standardizedFileURL
            guard let data = try? Data(contentsOf: candidate),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
                  manifest.id == pluginID else { continue }
            matches.append(packageURL)
        }
        guard matches.count == 1 else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        return matches[0]
    }

}
