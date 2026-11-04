import Combine
import Foundation
import LitheModuleAPI

struct LanguageServerLogsRequest: Equatable {
    let providerID: String
    let servers: [LSPStatusBarServer]
}

/// Separate presentation from application diagnostics, backed by the same redacted evidence.
@MainActor
final class LanguageServerLogsCoordinator: ObservableObject {
    @Published private(set) var request: LanguageServerLogsRequest?
    var present: (() -> Void)?
    func open(providerID: String, servers: [LSPStatusBarServer]) {
        request = .init(providerID: providerID, servers: servers)
        present?()
    }
}

@MainActor
final class LanguageServerLogsModel: ObservableObject {
    let logs: LogWindowModel
    @Published private(set) var servers: [LSPStatusBarServer] = []
    @Published private(set) var providerID = ""
    @Published private(set) var error: String?
    private let logging: any LogWindowLogging
    private let sink: (any LogSink)?
    private var selectionTask: Task<Void, Never>?
    private var revision = 0
    private var running = false

    init(logging: any LogWindowLogging, sink: (any LogSink)? = nil) {
        self.logging = logging; self.sink = sink
        var preferences = LogWindowPreferences()
        preferences.collapse = false
        preferences.query.channelPrefixes = ["lsp"]
        logs = LogWindowModel(logging: logging, preferences: preferences, sink: sink)
    }
    deinit { selectionTask?.cancel() }
    func apply(_ request: LanguageServerLogsRequest) {
        servers = request.servers
        select(request.providerID)
    }
    func start() {
        guard !running else { return }
        running = true
        logs.start()
    }
    func select(_ id: String) {
        providerID = id
        revision += 1
        let revision = revision
        selectionTask?.cancel()
        selectionTask = Task { [weak self, logging] in
            do {
                let channel = id.isEmpty ? "lsp" : try await logging.windowEngineChannel(providerID: id)
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                self.error = nil
                self.logs.changeQuery { $0.channelPrefixes = [channel] }
            } catch {
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                self.error = error.localizedDescription
                self.sink?.emit(AppLoggingDiagnosticsFailed(error: error))
            }
        }
    }
    func stop() {
        running = false; revision += 1
        selectionTask?.cancel(); selectionTask = nil
        logs.stop()
    }
}
