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
    /// The progress percentage the phase reports on the startup surface.
    ///
    /// The values come from `shared/fixtures/settings/startup-feedback-v1.json`
    /// so both products advance the same indicator in the same way.
    var progress: Int {
        switch self {
        case .preparing: return 10
        case .loadingPlugins: return 30
        case .initializingLanguageServices: return 50
        case .openingWorkspace: return 72
        case .restoringSession: return 88
        }
    }

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
