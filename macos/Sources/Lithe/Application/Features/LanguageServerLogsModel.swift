import Combine
import Foundation
import LitheModuleAPI

/// Backs the editor-area "LSP Logs" tab with the redacted v2 evidence the
/// application log window and diagnostics export also read. Core resolves each
/// server's channel; this model only keeps the selected server, the minimum
/// level and a clear point per server.
///
/// The tab owns the lifetime: `open` starts it and `stop` runs when the tab
/// closes or the workspace resets. A view disappearing (another tab selected)
/// does not stop it, because stopping discards the clear points.
@MainActor
final class LanguageServerLogsModel: ObservableObject {
    enum MinimumLevel: String, CaseIterable, Hashable {
        case info, warning, error

        /// v2 level names accepted by `LogWindowQuery.levels`.
        var levels: [String] {
            switch self {
            case .info: ["INFO", "WARN", "ERROR"]
            case .warning: ["WARN", "ERROR"]
            case .error: ["ERROR"]
            }
        }
    }

    let logs: LogWindowModel
    @Published private(set) var providerID = ""
    @Published private(set) var minimumLevel = MinimumLevel.info
    /// Channel resolution failure; query failures stay on `logs.error`.
    @Published private(set) var error: String?
    private let logging: any LogWindowLogging
    private let sink: (any LogSink)?
    private var selectionTask: Task<Void, Never>?
    private var revision = 0
    private var running = false
    private var logsStarted = false
    /// The server whose channel the inner query currently shows.
    private var appliedProviderID: String?
    /// "Clear View" hides only the selected server's rows; switching servers
    /// swaps these points instead of clearing every server at once.
    private var clearPoints: [String: [String: UInt64]] = [:]

    init(logging: any LogWindowLogging, sink: (any LogSink)? = nil) {
        self.logging = logging
        self.sink = sink
        var preferences = LogWindowPreferences()
        preferences.collapse = false
        preferences.query.levels = MinimumLevel.info.levels
        logs = LogWindowModel(logging: logging, preferences: preferences, sink: sink)
    }

    deinit { selectionTask?.cancel() }

    /// Starts the tab's query for `providerID`. An empty ID waits until the view
    /// picks the first known server.
    func open(providerID: String) {
        running = true
        select(providerID)
    }

    func select(_ id: String) {
        guard running else { providerID = id; return }
        guard id != providerID || id != appliedProviderID else { return }
        providerID = id
        error = nil
        revision += 1
        let revision = revision
        selectionTask?.cancel()
        selectionTask = nil
        guard !id.isEmpty else { return }
        selectionTask = Task { [weak self, logging] in
            do {
                let channel = try await logging.windowEngineChannel(providerID: id)
                guard let self, !Task.isCancelled, self.running, self.revision == revision else { return }
                self.show(channel: channel, for: id)
            } catch {
                guard let self, !Task.isCancelled, self.running, self.revision == revision else { return }
                self.error = error.localizedDescription
                self.sink?.emit(AppLoggingDiagnosticsFailed(error: error))
            }
        }
    }

    func setMinimumLevel(_ level: MinimumLevel) {
        guard level != minimumLevel else { return }
        minimumLevel = level
        guard logsStarted else { return }
        logs.changeQuery { $0.levels = level.levels }
    }

    /// Hides the selected server's current rows. Collected logs are not deleted.
    func clear() {
        guard logsStarted else { return }
        logs.clearDisplay()
    }

    func retry() {
        if error != nil { select(providerID) } else { logs.retry() }
    }

    func stop() {
        running = false
        revision += 1
        selectionTask?.cancel()
        selectionTask = nil
        if logsStarted { logs.stop() }
        logsStarted = false
        appliedProviderID = nil
        clearPoints = [:]
        error = nil
    }

    private func show(channel: String, for id: String) {
        if let applied = appliedProviderID { clearPoints[applied] = logs.displayWatermarks }
        logs.displayWatermarks = clearPoints[id] ?? [:]
        appliedProviderID = id
        let levels = minimumLevel.levels
        logs.changeQuery {
            $0.channelPrefixes = [channel]
            $0.levels = levels
        }
        if !logsStarted {
            logsStarted = true
            logs.start()
        }
    }
}
