import Foundation

// Note: 宿主集成的划分见 .agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md

/// Start parameters of the Rust Core launch a host integration builds on.
/// The set is closed: an integration is host code a plugin names in its
/// manifest, never something a plugin can add.
package enum LanguageServerHostIntegrationCoreLaunch: Equatable, Sendable {
    case jdt(JDTLSLaunchResources)

    package var jdtlsLaunchResources: JDTLSLaunchResources? {
        switch self {
        case .jdt(let resources): resources
        }
    }
}

/// What a host integration adds to one start of the language server that
/// declares it. The language-server pipeline carries this value from the
/// integration to Rust Core without interpreting it.
package struct LanguageServerHostIntegrationLaunch: Equatable, Sendable {
    /// Runtime the server process runs on, when the integration supplies one.
    package let runtimeExecutableURL: URL?
    package let coreLaunch: LanguageServerHostIntegrationCoreLaunch?

    package init(
        runtimeExecutableURL: URL? = nil,
        coreLaunch: LanguageServerHostIntegrationCoreLaunch? = nil
    ) {
        self.runtimeExecutableURL = runtimeExecutableURL?.standardizedFileURL
        self.coreLaunch = coreLaunch
    }
}

package enum LanguageServerHostIntegrationResolution: Equatable, Sendable {
    case available(LanguageServerHostIntegrationLaunch)
    /// The integration cannot start the server; the message tells the user why.
    case unavailable(String)
}

/// Resolves the host integration a provider declares for one start. `nil`
/// means the provider declares none and starts as a plain language server.
package typealias LanguageServerHostIntegrationResolver = @MainActor (
    LanguageProviderDescriptor
) -> LanguageServerHostIntegrationResolution?
