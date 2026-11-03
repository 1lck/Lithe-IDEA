import Combine
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Observes the session's bounded log buffer without relaying every log through AppModel.
@MainActor
final class LanguageServerLogsModel: ObservableObject {
    enum MinimumLevel: CaseIterable {
        case info, warning, error

        func includes(_ level: LanguageServerLogLevel) -> Bool {
            switch self {
            case .info: true
            case .warning: level != .info
            case .error: level == .error
            }
        }
    }

    @Published var providerID = ""
    @Published var minimumLevel: MinimumLevel = .info
    @Published private(set) var entries: [LanguageServerLogEntry] = []
    @Published private var clearedIDs: Set<UUID> = []
    private var observation: AnyCancellable?

    var visibleEntries: [LanguageServerLogEntry] {
        entries.reversed().filter {
            $0.providerID == providerID && minimumLevel.includes($0.level) && !clearedIDs.contains($0.id)
        }
    }

    func bind(_ sessions: LanguageToolingSessionManager) {
        observation = sessions.$languageServerLogs.sink { [weak self] entries in
            self?.replace(entries)
        }
    }

    func replace(_ entries: [LanguageServerLogEntry]) {
        // The session retains at most 100 entries. Clearing is a presentation
        // watermark, not deletion of persistent diagnostics or another server's logs.
        let retainedIDs = Set(entries.map(\.id))
        clearedIDs.formIntersection(retainedIDs)
        self.entries = entries
    }

    func clear() {
        clearedIDs.formUnion(entries.filter { $0.providerID == providerID }.map(\.id))
    }

    func reset() {
        providerID = ""
        minimumLevel = .info
        entries = []
        clearedIDs = []
    }
}
