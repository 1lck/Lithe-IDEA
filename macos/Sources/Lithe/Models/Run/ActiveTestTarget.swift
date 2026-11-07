import Foundation
import LitheModuleAPI
import LitheCoreContracts

/// The selected test scope, preserved when rerunning from the main toolbar.
struct ActiveTestTarget: Equatable, Sendable {
    let providerID: String
    let scope: LanguageTestScope

    var name: String {
        switch scope {
        case .workspace: L10n.string("Workspace")
        case .file(let url): url.lastPathComponent
        case .testCase(let identifier, _, _): identifier
        }
    }
}
