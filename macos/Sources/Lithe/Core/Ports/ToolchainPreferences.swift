import Foundation
import LitheCoreContracts
import LitheModuleAPI

enum ToolchainPreferenceError: LocalizedError {
    case invalid, conflict
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.string("The saved toolchain settings are invalid.")
        case .conflict: L10n.string("Project environment settings changed on disk. Reload before saving; your draft has been kept.")
        }
    }
}

/// Machine-local tool choices only. The revision never exposes Run documents,
/// environment variables or filesystem write authority to the settings model.
struct ToolchainPreferencesSnapshot: Equatable, Sendable {
    let workspace: URL
    let document: ToolingJSONValue
    let revision: String
}

struct ToolchainPreferenceAddress: Hashable, Sendable {
    let directory: String
    let consumer: String?
    let tool: String
}

struct ToolchainPreferenceReading: Equatable, Sendable {
    let stored: ToolingJSONValue?
    let fixed: FixedToolchainSelection?
    let source: String
}

@MainActor
protocol ToolchainPreferencesStoring: AnyObject {
    func load(workspace: URL) async throws -> ToolchainPreferencesSnapshot
    func inspect(_ address: ToolchainPreferenceAddress, snapshot: ToolchainPreferencesSnapshot) throws -> ToolchainPreferenceReading
    func save(_ value: ToolingJSONValue?, at address: ToolchainPreferenceAddress,
              expecting snapshot: ToolchainPreferencesSnapshot) async throws -> ToolchainPreferencesSnapshot
}
