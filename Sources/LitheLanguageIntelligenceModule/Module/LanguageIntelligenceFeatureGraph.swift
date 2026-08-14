import Foundation
import LitheModuleAPI

@MainActor
package final class LanguageIntelligenceFeatureGraph: NSObject, LanguageIntelligenceServiceGraph {
    package let sessions: LanguageToolingSessionManager
    package let tools: LanguageServerToolService

    package init(sessions: LanguageToolingSessionManager, tools: LanguageServerToolService) {
        self.sessions = sessions
        self.tools = tools
    }

    package var isActive: Bool { !sessions.activeLanguageServerIDs.isEmpty }
    package var hasActiveLanguageServers: Bool { isActive }

    package func activate(context: ModuleContext) {
        for descriptor in sessions.catalogSnapshot.descriptors
        where descriptor.capabilities.contains(.languageServer) {
            Task { await tools.refreshCandidates(for: descriptor) }
        }
    }

    package func prepareForSleep() async throws {
        guard !isActive else {
            throw LanguageIntelligenceSleepError.activeServers(
                "Language servers are still active and cannot be put to sleep."
            )
        }
    }

    package func stop() async {
        sessions.stopAll()
        sessions.clearDiagnostics()
    }
}

private enum LanguageIntelligenceSleepError: LocalizedError {
    case activeServers(String)

    var errorDescription: String? {
        switch self {
        case .activeServers(let message): message
        }
    }
}
