import Foundation

/// Prepares and exports a whitelisted diagnostic bundle: the redacted
/// application log, an environment/performance snapshot, and a manifest --
/// never workspace source, editor buffers, or terminal history.
@MainActor
final class DiagnosticsExportService: ObservableObject {
    enum ExportState {
        case idle
        case preparing
        case awaitingConfirmation(RustCoreBridge.DiagnosticsManifestPayload)
        case exporting
        case completed(URL)
        case failed(String)
    }

    private static let environmentFileName = "environment.json"
    private static let manifestFileName = "manifest.json"
    /// The zip's top-level folder name once `--keepParent` wraps the staged
    /// content directory.
    private static let exportFolderName = "Lithe Diagnostics"

    private enum PrepareOutcome: Sendable {
        case success(manifest: RustCoreBridge.DiagnosticsManifestPayload, stagingRootURL: URL)
        case failure(String)
    }

    private enum ExportOutcome: Sendable {
        case success
        case failure(String)
    }

    private struct ManifestFileContents: Encodable {
        struct Environment: Encodable {
            let appVersion: String
            let osName: String
            let osVersion: String
            let cpuCoreCount: Int
            let memoryRssBytes: Int64
            let diskFreeBytes: Int64
        }

        struct FileEntry: Encodable {
            let relativePath: String
            let sizeBytes: Int64
            let description: String
        }

        let schemaVersion: Int
        let generatedAtEpochMilliseconds: Int64
        let environment: Environment
        let files: [FileEntry]
    }

    @Published private(set) var state: ExportState = .idle

    private let logDirectoryProviding: any LogDirectoryProviding
    private let fileStorage: any FileStorage
    private let systemDiagnostics: any SystemDiagnosticsProviding
    private let archiver: any DiagnosticsArchiving
    private let core: RustCoreBridge
    private let now: () -> Date

    private var stagingRootURL: URL?

    /// Bumped by `cancel()` and by each new `prepare()`/`export()`. A detached
    /// staging or archiving task captures the value it started with; if it no
    /// longer matches when the task finishes, the user cancelled (or restarted)
    /// meanwhile and the result is discarded instead of resurrecting state.
    private var operationGeneration = 0

    init(
        logDirectoryProviding: any LogDirectoryProviding,
        fileStorage: any FileStorage,
        systemDiagnostics: any SystemDiagnosticsProviding,
        archiver: any DiagnosticsArchiving,
        core: RustCoreBridge,
        now: @escaping () -> Date = Date.init
    ) {
        self.logDirectoryProviding = logDirectoryProviding
        self.fileStorage = fileStorage
        self.systemDiagnostics = systemDiagnostics
        self.archiver = archiver
        self.core = core
        self.now = now
    }

    func prepare() async {
        operationGeneration += 1
        let generation = operationGeneration
        state = .preparing
        if let stagingRootURL {
            try? fileStorage.removeItem(at: stagingRootURL)
        }
        stagingRootURL = nil

        let logFileURL = logDirectoryProviding.applicationLogFileURL
        let logDirectoryURL = logDirectoryProviding.defaultLogDirectory
        let fileStorage = fileStorage
        let systemDiagnostics = systemDiagnostics
        let core = core
        let generatedAtEpochMilliseconds = Int64(now().timeIntervalSince1970 * 1_000)
        let environmentFileName = Self.environmentFileName
        let exportFolderName = Self.exportFolderName

        let outcome = await Task.detached(priority: .userInitiated) { () -> PrepareOutcome in
            let rawLogText: String
            do {
                let data = try fileStorage.readData(from: logFileURL, options: [])
                rawLogText = String(data: data, encoding: .utf8) ?? ""
            } catch {
                return .failure("Could not read the application log: \(error.localizedDescription)")
            }

            guard case .success(let redactedLog) = core.redactDiagnosticText(rawLogText) else {
                return .failure("Could not redact the application log for export.")
            }

            let snapshot = systemDiagnostics.currentSnapshot(volumeURL: logDirectoryURL)
            let stagingRootURL = fileStorage.cacheDirectory()
                .appendingPathComponent("Lithe/diagnostics-export/\(UUID().uuidString)", isDirectory: true)
            let contentDirectoryURL = stagingRootURL
                .appendingPathComponent(exportFolderName, isDirectory: true)

            do {
                try fileStorage.createDirectory(at: contentDirectoryURL, withIntermediateDirectories: true)

                let logData = Data(redactedLog.redacted.utf8)
                try fileStorage.writeData(
                    logData,
                    to: contentDirectoryURL.appendingPathComponent(logFileURL.lastPathComponent, isDirectory: false),
                    options: [.atomic]
                )

                let environmentData = try JSONEncoder().encode(snapshot)
                try fileStorage.writeData(
                    environmentData,
                    to: contentDirectoryURL.appendingPathComponent(environmentFileName, isDirectory: false),
                    options: [.atomic]
                )

                let files = [
                    RustCoreBridge.DiagnosticsFileEntryInput(
                        relativePath: logFileURL.lastPathComponent,
                        sizeBytes: Int64(logData.count),
                        description: "Application log (redacted)"
                    ),
                    RustCoreBridge.DiagnosticsFileEntryInput(
                        relativePath: environmentFileName,
                        sizeBytes: Int64(environmentData.count),
                        description: "Environment and performance snapshot"
                    )
                ]

                switch core.buildDiagnosticsManifest(
                    environment: RustCoreBridge.DiagnosticsEnvironmentInfo(
                        appVersion: snapshot.appVersion,
                        osName: snapshot.osName,
                        osVersion: snapshot.osVersion,
                        cpuCoreCount: snapshot.cpuCoreCount,
                        memoryRssBytes: snapshot.memoryRSSBytes,
                        diskFreeBytes: snapshot.diskFreeBytes
                    ),
                    files: files,
                    generatedAtEpochMilliseconds: generatedAtEpochMilliseconds
                ) {
                case .success(let manifest):
                    return .success(manifest: manifest, stagingRootURL: stagingRootURL)
                case .failure:
                    try? fileStorage.removeItem(at: stagingRootURL)
                    return .failure("Could not build the diagnostics manifest.")
                }
            } catch {
                try? fileStorage.removeItem(at: stagingRootURL)
                return .failure("Could not stage diagnostic files: \(error.localizedDescription)")
            }
        }.value

        // A cancel() or a newer prepare() during the await invalidates this
        // result. Drop it and remove any staging directory the task created so
        // the confirmation state is not resurrected and no orphan is left.
        guard generation == operationGeneration else {
            if case .success(_, let resolvedStagingRootURL) = outcome {
                try? fileStorage.removeItem(at: resolvedStagingRootURL)
            }
            return
        }

        switch outcome {
        case .success(let manifest, let resolvedStagingRootURL):
            stagingRootURL = resolvedStagingRootURL
            state = .awaitingConfirmation(manifest)
        case .failure(let message):
            state = .failed(message)
        }
    }

    func export(to destinationURL: URL) async {
        guard case .awaitingConfirmation(let manifest) = state, let stagingRootURL else {
            state = .failed("No diagnostics bundle is ready to export.")
            return
        }
        operationGeneration += 1
        let generation = operationGeneration
        state = .exporting

        let fileStorage = fileStorage
        let archiver = archiver
        let contentDirectoryURL = stagingRootURL.appendingPathComponent(Self.exportFolderName, isDirectory: true)
        let manifestFileName = Self.manifestFileName

        let outcome = await Task.detached(priority: .userInitiated) { () -> ExportOutcome in
            do {
                let manifestContents = ManifestFileContents(
                    schemaVersion: manifest.schemaVersion,
                    generatedAtEpochMilliseconds: manifest.generatedAtEpochMilliseconds,
                    environment: ManifestFileContents.Environment(
                        appVersion: manifest.environment.appVersion,
                        osName: manifest.environment.osName,
                        osVersion: manifest.environment.osVersion,
                        cpuCoreCount: manifest.environment.cpuCoreCount,
                        memoryRssBytes: manifest.environment.memoryRssBytes,
                        diskFreeBytes: manifest.environment.diskFreeBytes
                    ),
                    files: manifest.files.map {
                        ManifestFileContents.FileEntry(
                            relativePath: $0.relativePath,
                            sizeBytes: $0.sizeBytes,
                            description: $0.description
                        )
                    }
                )
                let manifestData = try JSONEncoder().encode(manifestContents)
                try fileStorage.writeData(
                    manifestData,
                    to: contentDirectoryURL.appendingPathComponent(manifestFileName, isDirectory: false),
                    options: [.atomic]
                )
                try archiver.archive(directoryURL: contentDirectoryURL, toZipURL: destinationURL)
                return .success
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value

        try? fileStorage.removeItem(at: stagingRootURL)
        self.stagingRootURL = nil

        // Cancelled (or superseded) mid-archive: the staging cleanup above still
        // runs, but leave the user's cancelled state untouched.
        guard generation == operationGeneration else { return }

        switch outcome {
        case .success:
            state = .completed(destinationURL)
        case .failure(let message):
            state = .failed("Could not export the diagnostics bundle: \(message)")
        }
    }

    func cancel() {
        operationGeneration += 1
        if let stagingRootURL {
            try? fileStorage.removeItem(at: stagingRootURL)
        }
        stagingRootURL = nil
        state = .idle
    }
}
