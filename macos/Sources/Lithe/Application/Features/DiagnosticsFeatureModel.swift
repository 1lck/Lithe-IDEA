import Combine
import Foundation
import LitheModuleAPI

/// Log maintenance and the immutable export confirmation owned by the log window.
@MainActor
final class DiagnosticsFeatureModel: ObservableObject {
    enum Range: String, CaseIterable { case current, recent, day }
    private let service: DiagnosticsExportService
    private let now: () -> Date
    private let sink: (any LogSink)?
    private var observation: AnyCancellable?
    private var planning: Task<Void, Never>?
    private var filter = LogWindowQuery()
    private var environment: RustCoreBridge.LogEnvironment?
    @Published private(set) var state: DiagnosticsExportService.ExportState
    @Published var isPresented = false
    @Published var choosingDestination = false
    @Published var range: Range = .current { didSet { replan() } }
    @Published var currentFilterOnly = false { didSet { replan() } }
    @Published var includeEnvironment = true { didSet { replan() } }
    @Published private(set) var logError: String?
    @Published private(set) var diskBytes: UInt64 = 0
    @Published private(set) var isUpdatingLogs = false
    var manifest: RustCoreBridge.DiagnosticsManifestPayload? { service.confirmedManifest }
    func retry() { replan() }
    var estimatedBytes: UInt64 { service.estimatedBytes }
    var selectedChannels: [String] { filter.channelPrefixes }
    var isBusy: Bool {
        if case .exporting = state { return true }
        return isUpdatingLogs || choosingDestination
    }
    var isPlanning: Bool { if case .preparing = state { return true }; return false }
    var exportQuery: ApplicationLogQuery {
        var query = ApplicationLogQuery()
        switch range {
        case .current: query.session = "current"
        case .recent: query.session = "all"; query.recentSessions = 3
        case .day:
            query.session = "all"
            query.since = ISO8601DateFormatter().string(from: now().addingTimeInterval(-24 * 60 * 60))
        }
        if currentFilterOnly {
            query.channelPrefixes = filter.channelPrefixes
            query.levels = filter.levels
            query.expression = filter.expression
        }
        return query
    }
    init(service: DiagnosticsExportService, now: @escaping () -> Date = Date.init, sink: (any LogSink)? = nil) {
        self.service = service; self.now = now; self.sink = sink
        _state = Published(initialValue: service.state)
        observation = service.$state.sink { [weak self] in self?.state = $0 }
    }
    deinit { planning?.cancel() }
    func refreshStatus() async {
        do {
            let status = try await service.applicationLogging?.status()
            diskBytes = status?.diskBytes ?? 0
            logError = nil
        } catch {
            guard !error.isCancellation else { return }
            sink?.emit(AppLoggingDiagnosticsFailed(error: error))
            logError = L10n.string("Could not load logs. Try again.")
        }
    }
    func clearLogs() async {
        guard !isBusy else { return }
        isUpdatingLogs = true
        defer { isUpdatingLogs = false }
        do {
            try await service.applicationLogging?.clear()
            logError = nil
            await refreshStatus()
        } catch {
            sink?.emit(AppLoggingDiagnosticsFailed(error: error))
            logError = L10n.string("Could not clear logs. Try again.")
        }
    }
    func changeLogDirectory(to directory: URL) async -> Bool {
        guard !isBusy, let logging = service.applicationLogging else { return false }
        isUpdatingLogs = true
        defer { isUpdatingLogs = false }
        do {
            try await logging.changeDirectory(to: directory)
            logError = nil; await refreshStatus(); return true
        } catch {
            sink?.emit(AppLoggingDiagnosticsFailed(error: error))
            logError = L10n.string("Could not change the log directory. Try again.")
            return false
        }
    }
    func presentExport(filter: LogWindowQuery, environment: RustCoreBridge.LogEnvironment? = nil) {
        guard !isBusy else { return }
        self.filter = filter; self.environment = environment
        isPresented = false
        range = .current; currentFilterOnly = false; includeEnvironment = true
        isPresented = true
        replan()
    }
    private func replan() {
        guard isPresented, !isBusy else { return }
        planning?.cancel()
        service.cancel()
        let query = exportQuery, include = includeEnvironment, environment = environment, crashes = range != .current
        planning = Task {
            guard !Task.isCancelled else { return }
            await service.prepare(query: query, includeEnvironment: include,
                environment: environment, includeCrashes: crashes)
        }
    }
    func dismiss() { choosingDestination = false; planning?.cancel(); planning = nil; service.cancel(); isPresented = false }
    func export(to destinationURL: URL) async { await service.export(to: destinationURL) }
}
