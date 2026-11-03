import Foundation
import LitheModuleAPI

/// Freezes Core-redacted evidence before confirmation. Native storage and the
/// archiver own I/O; no source is reopened after the confirmation is displayed.
/// Staging remains in the registered application-log-state cache subtree, owned
/// by this confirmation and removed on replacement, cancellation or completion.
/// It is never reused across worktrees and never changes signed bundle bytes.
@MainActor
final class DiagnosticsExportService: ObservableObject {
    enum ExportState {
        case idle, preparing
        case awaitingConfirmation(RustCoreBridge.DiagnosticsManifestPayload)
        case exporting
        case completed(URL)
        case failed(String)
    }
    @Published private(set) var state: ExportState = .idle
    @Published private(set) var estimatedBytes: UInt64 = 0
    private let logDirectoryProviding: any LogDirectoryProviding
    private let fileStorage: any FileStorage
    private let systemDiagnostics: any SystemDiagnosticsProviding
    private let archiver: any DiagnosticsArchiving
    let applicationLogging: (any ApplicationLogging)?
    private let core: RustCoreBridge
    private let now: () -> Date
    private let crashReports: (any CrashReportCollecting)?
    private let sink: (any LogSink)?
    var environmentProvider: (() -> RustCoreBridge.LogEnvironment)?
    @Published private(set) var confirmedManifest: RustCoreBridge.DiagnosticsManifestPayload?
    private var stagingRootURL: URL?
    private var generation = 0
    private nonisolated static let folder = "Lithe Diagnostics"

    init(logDirectoryProviding: any LogDirectoryProviding, fileStorage: any FileStorage,
         systemDiagnostics: any SystemDiagnosticsProviding, archiver: any DiagnosticsArchiving,
         core: RustCoreBridge, applicationLogging: (any ApplicationLogging)? = nil,
         now: @escaping () -> Date = Date.init, crashReports: (any CrashReportCollecting)? = nil,
         sink: (any LogSink)? = nil) {
        self.logDirectoryProviding = logDirectoryProviding; self.fileStorage = fileStorage
        self.systemDiagnostics = systemDiagnostics; self.archiver = archiver; self.core = core
        self.applicationLogging = applicationLogging; self.now = now
        self.crashReports = crashReports; self.sink = sink
    }

    func prepare(query: ApplicationLogQuery = .init(), includeEnvironment: Bool = true,
                 environment: RustCoreBridge.LogEnvironment? = nil, includeCrashes: Bool = false) async {
        generation += 1
        let revision = generation
        let oldRoot = stagingRootURL
        stagingRootURL = nil; confirmedManifest = nil; state = .preparing; estimatedBytes = 0
        let storage = fileStorage, system = systemDiagnostics, core = core, crashes = crashReports, sink = sink
        let defaultRoot = logDirectoryProviding.defaultLogDirectory
        let date = now()
        let environment = environment ?? environmentProvider?()
        let root = storage.cacheDirectory().appendingPathComponent("Lithe/diagnostics-export/\(UUID().uuidString)", isDirectory: true)
        do {
            let collection = try await applicationLogging?.collect(query: query)
            try Task.checkCancellation()
            guard revision == generation else {
                if let oldRoot { await remove(oldRoot) }
                return
            }
            estimatedBytes = collection?.estimatedBytes ?? 0
            let staging = Task.detached(priority: .userInitiated) {
                if let oldRoot { Self.remove(oldRoot, storage: storage, sink: sink) }
                try Task.checkCancellation()
                let content = root.appendingPathComponent(Self.folder, isDirectory: true)
                try storage.createDirectory(at: content, withIntermediateDirectories: true)
                var files = collection?.files ?? []
                if includeCrashes, let crashes {
                    let cutoff = query.since.flatMap { ISO8601DateFormatter().date(from: $0) } ?? collection?.sessionStart ?? date
                    let reports = try crashes.collect(since: cutoff, until: date)
                    files.append(contentsOf: reports.files)
                    if !reports.status.isEmpty {
                        let index = files.firstIndex { $0.relativePath == "collection-status.txt" }
                        let original = index.map { files.remove(at: $0).data } ?? Data()
                        files.append(.init(relativePath: "collection-status.txt", data: original + Data((reports.status.joined(separator: "\n") + "\n").utf8)))
                    }
                }
                let snapshot = system.currentSnapshot(volumeURL: collection?.effectiveDirectory ?? defaultRoot)
                if includeEnvironment {
                    let summary = environment ?? .init(appVersion: snapshot.appVersion, osVersion: snapshot.osVersion,
                        architecture: "unknown", plugins: [])
                    // Host facts contain only version/architecture and trusted plugin IDs.
                    // Redact each scalar through Core before JSON serialization so text
                    // redaction can never turn JSON key/value syntax into invalid JSON.
                    func redact(_ value: String) throws -> String { try core.redactDiagnosticText(value).get().redacted }
                    let safe = RustCoreBridge.LogEnvironment(appVersion: try redact(summary.appVersion),
                        osVersion: try redact(summary.osVersion), architecture: try redact(summary.architecture),
                        plugins: try summary.plugins.map(redact))
                    files.append(.init(relativePath: "environment.json", data: try JSONEncoder().encode(safe)))
                }
                for file in files {
                    try Task.checkCancellation()
                    let target = content.appendingPathComponent(file.relativePath)
                    try storage.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try storage.writeData(file.data, to: target, options: .atomic)
                }
                let manifest = try core.buildDiagnosticsManifest(environment: .init(appVersion: snapshot.appVersion,
                    osName: snapshot.osName, osVersion: snapshot.osVersion, cpuCoreCount: snapshot.cpuCoreCount,
                    memoryRssBytes: snapshot.memoryRSSBytes, diskFreeBytes: snapshot.diskFreeBytes),
                    files: files.map { .init(relativePath: $0.relativePath, sizeBytes: Int64($0.data.count), description: "Core-redacted diagnostic evidence") },
                    generatedAtEpochMilliseconds: Int64(date.timeIntervalSince1970 * 1000)).get()
                try storage.writeData(JSONEncoder().encode(manifest), to: content.appendingPathComponent("manifest.json"), options: .atomic)
                return manifest
            }
            let manifest = try await withTaskCancellationHandler(operation: { try await staging.value }, onCancel: { staging.cancel() })
            guard revision == generation, !Task.isCancelled else {
                await remove(root); return
            }
            stagingRootURL = root; confirmedManifest = manifest; state = .awaitingConfirmation(manifest)
        } catch {
            await remove(root)
            if let oldRoot { await remove(oldRoot) }
            guard revision == generation else { return }
            if error.isCancellation { state = .idle; return }
            sink?.emit(AppDiagnosticsExportFailed(error: error, stage: "planning"))
            state = .failed(L10n.string("Could not prepare diagnostic logs. Try again."))
        }
    }

    func export(to destinationURL: URL) async {
        guard confirmedManifest != nil, let root = stagingRootURL else { return }
        if case .exporting = state { return }
        if case .completed = state { return }
        let revision = generation
        state = .exporting
        let archiver = archiver
        do {
            try await Task.detached(priority: .userInitiated) {
                try archiver.archive(directoryURL: root.appendingPathComponent(Self.folder), toZipURL: destinationURL)
            }.value
            await remove(root)
            guard revision == generation else { return }
            stagingRootURL = nil; state = .completed(destinationURL)
        } catch {
            guard revision == generation else { await remove(root); return }
            if error.isCancellation { state = .awaitingConfirmation(confirmedManifest!); return }
            sink?.emit(AppDiagnosticsExportFailed(error: error, stage: "archive"))
            state = .failed(L10n.string("Could not export diagnostic logs. Try again."))
        }
    }
    func cancel() {
        generation += 1
        let archiveOwnsStaging: Bool
        if case .exporting = state { archiveOwnsStaging = true } else { archiveOwnsStaging = false }
        if let root = stagingRootURL, !archiveOwnsStaging {
            let storage = fileStorage, sink = sink
            Task.detached { Self.remove(root, storage: storage, sink: sink) }
        }
        stagingRootURL = nil; confirmedManifest = nil; state = .idle
    }
    private func remove(_ root: URL) async {
        let storage = fileStorage, sink = sink
        await Task.detached { Self.remove(root, storage: storage, sink: sink) }.value
    }
    private nonisolated static func remove(_ root: URL, storage: any FileStorage, sink: (any LogSink)?) {
        do { try storage.removeItem(at: root) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileNoSuchFileError { return }
            sink?.emit(AppDiagnosticsExportFailed(error: error, stage: "cleanup"))
        }
    }
}
