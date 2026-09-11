import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Answers language-server capability questions without owning presentation.
@MainActor
struct LanguageCapabilityPolicy {
    func supports(
        _ feature: LanguageServerFeatureSet,
        documentURL: URL,
        sessions: LanguageToolingSessionManager?
    ) -> Bool {
        sessions?.features(for: documentURL).contains(feature) == true
    }
}
