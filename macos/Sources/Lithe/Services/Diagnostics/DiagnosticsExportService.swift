import LitheModuleAPI
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
    let applicationLogging: (any ApplicationLogging)?
    private let logSink: (any LogSink)?
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
        logSink: (any LogSink)? = nil,
        applicationLogging: (any ApplicationLogging)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.logDirectoryProviding = logDirectoryProviding
        self.fileStorage = fileStorage
        self.systemDiagnostics = systemDiagnostics
        self.archiver = archiver
        self.logSink = logSink ?? core.coreLogSink
        self.core = core
        self.applicationLogging = applicationLogging
        self.now = now
    }

    func prepare(query: ApplicationLogQuery = ApplicationLogQuery()) async {
        operationGeneration += 1
        let generation = operationGeneration
        state = .preparing
        if let stagingRootURL {
            Self.removeStaging(stagingRootURL, storage: fileStorage, logSink: logSink)
        }
        stagingRootURL = nil

        let collection: ApplicationLogCollection?
        do { collection = try await applicationLogging?.collect(query: query) }
        catch { logSink?.emit(AppDiagnosticsExportFailed(error: error, stage: "collect")); if generation == operationGeneration { state = .failed(error.localizedDescription) }; return }
        guard generation == operationGeneration else { return }
        let logDirectoryURL = collection?.effectiveDirectory ?? logDirectoryProviding.defaultLogDirectory
        let logSink = logSink
        let fileStorage = fileStorage
        let systemDiagnostics = systemDiagnostics
        let core = core
        let generatedAtEpochMilliseconds = Int64(now().timeIntervalSince1970 * 1_000)
        let environmentFileName = Self.environmentFileName
        let exportFolderName = Self.exportFolderName

        let outcome = await Task.detached(priority: .userInitiated) { () -> PrepareOutcome in
            // A host without an installed collector exports only the system snapshot.
            // Never reopen v1 files: macOS v2 evidence comes exclusively from collect.
            let collectedFiles = collection?.files ?? []

            let snapshot = systemDiagnostics.currentSnapshot(volumeURL: logDirectoryURL)
            let stagingRootURL = fileStorage.cacheDirectory()
                .appendingPathComponent("Lithe/diagnostics-export/\(UUID().uuidString)", isDirectory: true)
            let contentDirectoryURL = stagingRootURL
                .appendingPathComponent(exportFolderName, isDirectory: true)

            do {
                try fileStorage.createDirectory(at: contentDirectoryURL, withIntermediateDirectories: true)

                for file in collectedFiles {
                    let destination = contentDirectoryURL.appendingPathComponent(file.relativePath)
                    try fileStorage.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileStorage.writeData(file.data, to: destination, options: [.atomic])
                }

                let environmentData = try JSONEncoder().encode(snapshot)
                try fileStorage.writeData(
                    environmentData,
                    to: contentDirectoryURL.appendingPathComponent(environmentFileName, isDirectory: false),
                    options: [.atomic]
                )

                let files = collectedFiles.map {
                    RustCoreBridge.DiagnosticsFileEntryInput(relativePath: $0.relativePath,
                        sizeBytes: Int64($0.data.count), description: "Application log (redacted)")
                } + [RustCoreBridge.DiagnosticsFileEntryInput(relativePath: environmentFileName,
                    sizeBytes: Int64(environmentData.count), description: "Environment and performance snapshot")]

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
                case .failure(let error):
                    logSink?.emit(AppDiagnosticsExportFailed(error: LogFailure(domain: "RustCore", code: error.code), stage: "manifest"))
                    Self.removeStaging(stagingRootURL, storage: fileStorage, logSink: logSink)
                    return .failure("Could not build the diagnostics manifest.")
                }
            } catch {
                logSink?.emit(AppDiagnosticsExportFailed(error: error, stage: "prepare"))
                Self.removeStaging(stagingRootURL, storage: fileStorage, logSink: logSink)
                return .failure("Could not stage diagnostic files: \(error.localizedDescription)")
            }
        }.value

        // A cancel() or a newer prepare() during the await invalidates this
        // result. Drop it and remove any staging directory the task created so
        // the confirmation state is not resurrected and no orphan is left.
        guard generation == operationGeneration else {
            if case .success(_, let resolvedStagingRootURL) = outcome {
                Self.removeStaging(resolvedStagingRootURL, storage: fileStorage, logSink: logSink)
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

        let logSink = logSink
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
                logSink?.emit(AppDiagnosticsExportFailed(error: error, stage: "archive"))
                return .failure(error.localizedDescription)
            }
        }.value

        Self.removeStaging(stagingRootURL, storage: fileStorage, logSink: logSink)
        if self.stagingRootURL == stagingRootURL { self.stagingRootURL = nil }

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
            Self.removeStaging(stagingRootURL, storage: fileStorage, logSink: logSink)
        }
        stagingRootURL = nil
        state = .idle
    }
    private nonisolated static func removeStaging(_ url: URL, storage: any FileStorage, logSink: (any LogSink)?) {
        do { try storage.removeItem(at: url) }
        catch where (error as NSError).domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) {
            // log-exempt: 预期的缺失：暂存目录已被取消或另一次清理移除
        } catch { logSink?.emit(AppDiagnosticsCleanupFailed(error: error)) }
    }

}
