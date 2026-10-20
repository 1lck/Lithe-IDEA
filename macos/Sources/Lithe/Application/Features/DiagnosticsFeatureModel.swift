import Combine
import Foundation

/// Owns the shared logs/diagnostics page state and immutable export confirmation.
@MainActor
final class DiagnosticsFeatureModel: ObservableObject {
    private let service: DiagnosticsExportService
    private var observation: AnyCancellable?

    @Published private(set) var state: DiagnosticsExportService.ExportState
    @Published var isPresented = false
    private(set) var exportQuery = ApplicationLogQuery()
    @Published var logCategory = "all" { didSet { invalidateLogQuery() } }
    @Published var logSession = "current" { didSet { invalidateLogQuery() } }
    @Published var logLevel = "info" { didSet { invalidateLogQuery() } }
    @Published var logSearch = "" { didSet { invalidateLogQuery() } }
    @Published var logSince = "" { didSet { invalidateLogQuery() } }
    @Published var logUntil = "" { didSet { invalidateLogQuery() } }
    @Published private(set) var logContent = ""
    @Published private(set) var logError: String?
    @Published private(set) var logsCleared = false
    @Published private(set) var logTruncated = false
    @Published private(set) var droppedEvents = 0
    @Published private(set) var writeFailures = 0
    @Published private(set) var diagnosticEnabled = false
    @Published private(set) var diagnosticCategory: String?
    @Published private(set) var isLoadingLogs = false
    @Published private(set) var isUpdatingLogs = false
    private var queryGeneration = 0

    var isBusy: Bool {
        if case .preparing = state { return true }
        if case .exporting = state { return true }
        return isLoadingLogs || isUpdatingLogs
    }

    var logQuery: ApplicationLogQuery {
        ApplicationLogQuery(category: logCategory == "all" ? nil : logCategory,
            minimumLevel: logLevel, session: logSession,
            search: logSearch.isEmpty ? nil : logSearch,
            since: logSince.isEmpty ? nil : logSince, until: logUntil.isEmpty ? nil : logUntil)
    }

    private func invalidateLogQuery() {
        queryGeneration += 1
        logContent = ""
        logTruncated = false
        logError = nil
        logsCleared = false
    }

    func refreshLogs() async {
        guard !isLoadingLogs else { return }
        let generation = queryGeneration
        let query = logQuery
        isLoadingLogs = true
        // Filter changes invalidate only the result; this request still owns loading.
        defer { isLoadingLogs = false }
        do {
            guard let collection = try await service.applicationLogging?.collect(query: query),
                  generation == queryGeneration else { return }
            let lines = collection.content.split(separator: "\n", omittingEmptySubsequences: false)
            logContent = String(lines.suffix(2000).joined(separator: "\n").suffix(200_000))
            logTruncated = collection.truncated || logContent.count < collection.content.count
            diagnosticEnabled = collection.diagnosticEnabled
            diagnosticCategory = collection.diagnosticCategory
            droppedEvents = collection.droppedEvents
            writeFailures = collection.writeFailures
            logError = nil
        } catch { if generation == queryGeneration { logError = error.localizedDescription } }
    }

    func setDiagnosticEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isUpdatingLogs = true
        await service.applicationLogging?.configureDiagnostic(
            category: logCategory == "all" ? nil : logCategory, enabled: enabled)
        isUpdatingLogs = false
        await refreshLogs()
    }

    func clearLogs() async {
        guard !isBusy else { return }
        logsCleared = false
        logError = nil
        isUpdatingLogs = true
        do {
            try await service.applicationLogging?.clear()
            isUpdatingLogs = false
            await refreshLogs()
            if logError == nil { logsCleared = true }
        } catch {
            isUpdatingLogs = false
            logError = error.localizedDescription
        }
    }

    func changeLogDirectory(to directory: URL) async -> Bool {
        guard !isBusy, let logging = service.applicationLogging else { return false }
        isUpdatingLogs = true
        do {
            try await logging.changeDirectory(to: directory)
            isUpdatingLogs = false
            await refreshLogs()
            return true
        } catch {
            isUpdatingLogs = false
            logError = error.localizedDescription
            return false
        }
    }

    init(service: DiagnosticsExportService) {
        self.service = service
        _state = Published(initialValue: service.state)
        observation = service.$state.sink { [weak self] state in self?.state = state }
    }

    func presentExport() {
        guard !isBusy else { return }
        let query = logQuery
        exportQuery = query
        isPresented = true
        Task { await service.prepare(query: query) }
    }

    func dismiss() {
        service.cancel()
        isPresented = false
    }

    func export(to destinationURL: URL) async {
        await service.export(to: destinationURL)
    }
}
