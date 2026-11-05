import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// Records the installation a `tool` field chose in the new project's tool
/// pins, the same document the Toolchains settings page edits.
///
/// Nothing new is stored: the pin is the workspace-level default of that tool in
/// `.lithe/run/local.json`, so the project resolves the tool the way the user
/// picked it from the first open, and the settings page shows and changes it.
@MainActor
enum MacProjectToolPins {
    /// Writes `pin` into `project`. It reads the document first and saves
    /// against that revision, so a file somebody else changed in between is
    /// reported as a conflict and never overwritten.
    static func save(
        _ pin: ProjectGenerationPlan.ToolPin,
        in project: URL,
        using store: any ToolchainPreferencesStoring
    ) async throws {
        let snapshot = try await store.load(workspace: project)
        // `pinAs: "project"` is the only pin kind a generator can ask for, and
        // it is the workspace default: directory "." with no consumer.
        let address = ToolchainPreferenceAddress(directory: ".", consumer: nil, tool: pin.tool)
        _ = try await store.save(.object(["home": .string(pin.home)]), at: address, expecting: snapshot)
    }
}
