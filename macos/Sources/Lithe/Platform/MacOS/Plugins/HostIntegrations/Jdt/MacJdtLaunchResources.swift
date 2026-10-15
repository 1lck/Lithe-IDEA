import Foundation
import LitheCoreContracts

// Note: Java 语言服务器插件化与 jdt 宿主集成见 .agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md

/// Maps the files a plugin declares for the `jdt` integration to the JDT LS
/// launch of Rust Core. It hands over exactly the declared files and never
/// searches the app bundle or the machine for JDT LS, so removing the plugin
/// removes Java language support with it.
struct MacJdtLaunchResources {
    enum IntegrationError: LocalizedError, Equatable {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                "The Java Support plugin does not provide \(name). Reinstall the plugin."
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resources(
        from integration: MacPluginLanguageServerLaunchResolver.HostIntegration,
        javaRuntimes: [JavaLanguageServiceRuntime]
    ) throws -> JDTLSLaunchResources {
        guard let launcherJarURL = integration.entryURL else {
            throw IntegrationError.missingResource("the JDT LS launcher")
        }
        guard let configurationURL = integration.resource("configuration") else {
            throw IntegrationError.missingResource("the JDT LS configuration")
        }
        guard let lombokAgentURL = integration.resource("lombokAgent") else {
            throw IntegrationError.missingResource("the Lombok agent")
        }
        return JDTLSLaunchResources(
            launcherJarURL: launcherJarURL,
            // The packaged directory is passed as is: Rust Core gives Equinox a
            // writable copy in the host cache and never writes into the package.
            configurationDirectoryURL: configurationURL,
            lombokAgentURL: lombokAgentURL,
            javaExtensionBundleURLs: (integration.resources["extensionBundleDirectories"] ?? [])
                .flatMap(bundles(in:)),
            javaTestRunnerURL: integration.resource("testRunner"),
            javaRuntimes: javaRuntimes
        )
    }

    /// JAR files directly inside a declared bundle directory, sorted by name
    /// so JDT LS loads the same extensions in the same order on every launch.
    private func bundles(in directoryURL: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter {
                $0.pathExtension == "jar"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
