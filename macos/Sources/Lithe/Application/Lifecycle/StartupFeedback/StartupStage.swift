import Foundation

/// Coarse-grained startup phases shared by both Lithe products.
///
/// The phase identifiers and their wording are owned by
/// `shared/contracts/startup-feedback-v1.md`. Both products use the same
/// identifiers so a phase reads the same way in either interface and the
/// shared contract gate can detect a divergence.
///
/// Fine-grained language-server phases keep using the vocabulary of
/// `shared/fixtures/lsp/project-preparation-v1.json`; this enum only describes
/// product-level startup steps.
enum StartupStage: String, CaseIterable, Sendable {
    case preparing = "preparing"
    case loadingPlugins = "loadingPlugins"
    case initializingLanguageServices = "initializingLanguageServices"
    case openingWorkspace = "openingWorkspace"
    case restoringSession = "restoringSession"
}

extension StartupStage {
    /// The English wording of the phase.
    ///
    /// macOS localizes with the English sentence as the key, so the wording must
    /// stay identical to the shared contract.
    var englishLabel: String {
        switch self {
        case .preparing: return "Preparing Lithe"
        case .loadingPlugins: return "Loading plugins"
        case .initializingLanguageServices: return "Initializing language services"
        case .openingWorkspace: return "Opening workspace"
        case .restoringSession: return "Restoring your last session"
        }
    }
}
