import Combine
import Foundation

/// UI-facing projection for the diagnostic-bundle export flow. Owns sheet
/// presentation state so Views depend on this feature model instead of the
/// underlying service directly.
@MainActor
final class DiagnosticsFeatureModel: ObservableObject {
    private let service: DiagnosticsExportService
    private var observation: AnyCancellable?

    @Published private(set) var state: DiagnosticsExportService.ExportState
    @Published var isPresented = false
    @Published var logCategory = "all"
    @Published var logSession = "current"
    @Published var logLevel = "info"
    @Published var logSearch = ""
    @Published var logSince = ""
    @Published var logUntil = ""
    @Published private(set) var logContent = ""
    @Published private(set) var logStatus = ""
    @Published private(set) var diagnosticEnabled = false
    @Published private(set) var isLoadingLogs = false
    private var queryGeneration = 0

    var logQuery: ApplicationLogQuery {
        ApplicationLogQuery(category: logCategory == "all" ? nil : logCategory,
            minimumLevel: logLevel, session: logSession,
            search: logSearch.isEmpty ? nil : logSearch,
            since: logSince.isEmpty ? nil : logSince, until: logUntil.isEmpty ? nil : logUntil)
    }

    func refreshLogs() async {
        queryGeneration += 1
        let generation = queryGeneration
        isLoadingLogs = true
        defer { if generation == queryGeneration { isLoadingLogs = false } }
        do {
            guard let collection = try await service.applicationLogging?.collect(query: logQuery),
                  generation == queryGeneration else { return }
            let display = String(collection.content.suffix(200_000))
            logContent = display
            diagnosticEnabled = collection.diagnosticEnabled
            logStatus = "\(collection.effectiveDirectory.path) · dropped=\(collection.droppedEvents) · failures=\(collection.writeFailures)"
            if collection.truncated || display.count < collection.content.count {
                logStatus += " · " + String(localized: "Earlier log content omitted")
            }
        } catch { if generation == queryGeneration { logStatus = error.localizedDescription } }
    }

    func setDiagnosticEnabled(_ enabled: Bool) async {
        await service.applicationLogging?.configureDiagnostic(
            category: logCategory == "all" ? nil : logCategory, enabled: enabled)
        await refreshLogs()
    }

    func clearLogs() async {
        do { try await service.applicationLogging?.clear(); await refreshLogs() }
        catch { logStatus = error.localizedDescription }
    }


    init(service: DiagnosticsExportService) {
        self.service = service
        _state = Published(initialValue: service.state)
        observation = service.$state.sink { [weak self] state in self?.state = state }

    }

    func presentExport() {
        isPresented = true
        Task { await service.prepare(query: logQuery) }
    }

    func dismiss() {
        service.cancel()
        isPresented = false
    }

    func export(to destinationURL: URL) async {
        await service.export(to: destinationURL)
    }
}
