import Foundation
import LitheCoreContracts

// Note: 宿主集成的划分见 .agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md

/// Native host code a plugin's language server names in its manifest through
/// `hostIntegration.id`. Everything specific to one integration lives in its
/// own type; the language-server pipeline and the composition root only see
/// this protocol.
@MainActor
protocol MacLanguageServerHostIntegration {
    /// The `hostIntegration.id` this type implements.
    var id: String { get }

    /// Called once the installed plugins are known, before any server starts.
    /// `plugins` are the accepted packages. `installed` is every package the
    /// scan found, or `nil` when the scan itself failed and nothing is known
    /// about what is installed.
    func pluginsDidLoad(_ plugins: [InstalledPluginPackage], installed: [InstalledPluginPackage]?)

    /// What the integration adds to one start of the declaring server.
    func launch(
        for source: DeclarativeLanguageServerLaunchSource
    ) -> LanguageServerHostIntegrationResolution

    /// Identity of the server state kept for a workspace, or `nil` when the
    /// integration keeps none.
    func workspaceFingerprint(
        for source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL
    ) throws -> String?

    /// Discards the state kept for a workspace so the server rebuilds it.
    func resetWorkspaceState(at workspaceRootURL: URL, fingerprint: String?) throws

    /// Removes state of workspaces that are no longer used. Returns how many
    /// workspaces were removed.
    func pruneWorkspaceState(at workspaceRootURL: URL, fingerprint: String?) throws -> Int
}

/// The integrations this build of Lithe provides, looked up by the ID a
/// language server declares.
@MainActor
struct MacLanguageServerHostIntegrations {
    enum IntegrationError: LocalizedError, Equatable {
        case notDeclared(String)

        var errorDescription: String? {
            switch self {
            case .notDeclared(let displayName):
                "\(displayName) keeps no workspace state that Lithe can reset."
            }
        }
    }

    private let integrations: [String: any MacLanguageServerHostIntegration]

    init(_ integrations: [any MacLanguageServerHostIntegration]) {
        self.integrations = Dictionary(uniqueKeysWithValues: integrations.map { ($0.id, $0) })
    }

    func pluginsDidLoad(_ plugins: [InstalledPluginPackage], installed: [InstalledPluginPackage]?) {
        for id in integrations.keys.sorted() {
            integrations[id]?.pluginsDidLoad(plugins, installed: installed)
        }
    }

    /// `nil` when the provider declares no integration.
    func launch(for descriptor: LanguageProviderDescriptor) -> LanguageServerHostIntegrationResolution? {
        guard let id = descriptor.languageServerLaunch?.hostIntegrationID else { return nil }
        guard let declared = declared(by: descriptor) else {
            // Rust Core rejects unknown IDs at validation, so this is a
            // manifest accepted by a newer contract than this host implements.
            return .unavailable("\(descriptor.displayName) needs the \(id) integration, which this build of Lithe does not provide.")
        }
        return declared.integration.launch(for: declared.source)
    }

    func workspaceFingerprint(
        for descriptor: LanguageProviderDescriptor,
        workspaceRootURL: URL
    ) throws -> String? {
        guard let declared = declared(by: descriptor) else { return nil }
        return try declared.integration.workspaceFingerprint(
            for: declared.source,
            workspaceRootURL: workspaceRootURL
        )
    }

    func resetWorkspaceState(
        for descriptor: LanguageProviderDescriptor,
        workspaceRootURL: URL,
        fingerprint: String?
    ) throws {
        guard let declared = declared(by: descriptor) else {
            throw IntegrationError.notDeclared(descriptor.displayName)
        }
        try declared.integration.resetWorkspaceState(at: workspaceRootURL, fingerprint: fingerprint)
    }

    func pruneWorkspaceState(
        for descriptor: LanguageProviderDescriptor,
        workspaceRootURL: URL,
        fingerprint: String?
    ) throws -> Int {
        guard let declared = declared(by: descriptor) else { return 0 }
        return try declared.integration.pruneWorkspaceState(at: workspaceRootURL, fingerprint: fingerprint)
    }

    private func declared(by descriptor: LanguageProviderDescriptor) -> (
        integration: any MacLanguageServerHostIntegration,
        source: DeclarativeLanguageServerLaunchSource
    )? {
        guard let launch = descriptor.languageServerLaunch,
              let id = launch.hostIntegrationID,
              let integration = integrations[id],
              let source = launch.launchSource else { return nil }
        return (integration, source)
    }
}
