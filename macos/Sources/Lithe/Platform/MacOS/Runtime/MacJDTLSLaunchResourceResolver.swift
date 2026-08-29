import Foundation
import LitheCoreContracts

enum MacJDTLSLaunchResourceResolution {
    case direct(JDTLSLaunchResources)
    case wrapperFallback
    case unavailable(String)
}

struct MacJDTLSLaunchResourceResolver {
    private static let equinoxLauncherPrefix = "org.eclipse.equinox.launcher_"
    private static let javaDebugBundlePrefix = "com.microsoft.java.debug.plugin-"
    private static let javaTestBundlePrefix = "com.microsoft.java.test.plugin-"

    private let bundledJdtlsRootURL: URL?
    private let fileManager: FileManager

    init(
        bundledJdtlsRootURL: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("LanguageServers/jdtls", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.bundledJdtlsRootURL = bundledJdtlsRootURL?.standardizedFileURL
        self.fileManager = fileManager
    }

    func resolve(for executableURL: URL) -> MacJDTLSLaunchResourceResolution {
        do {
            return .direct(try directLaunchResources(for: executableURL))
        } catch {
            guard isBundled(executableURL) else { return .wrapperFallback }
            return .unavailable(
                "Bundled JDTLS direct-launch resources are incomplete. "
                    + "Reinstall Lithe. \(error.localizedDescription)"
            )
        }
    }

    private func directLaunchResources(for executableURL: URL) throws -> JDTLSLaunchResources {
        for rootURL in installationRoots(for: executableURL) {
            let pluginsURL = rootURL.appendingPathComponent("plugins", isDirectory: true)
            let configurationURL = configurationDirectory(in: rootURL)
            let lombokURL = rootURL.appendingPathComponent("lombok/lombok.jar")
            let javaDebugURL = try firstJavaDebugBundle(
                in: rootURL.appendingPathComponent("java-debug", isDirectory: true)
            )
            let javaTestBundleURLs = try javaTestExtensionBundles(
                in: rootURL.appendingPathComponent("java-test/extensions", isDirectory: true)
            )
            guard let launcherURL = try firstEquinoxLauncher(in: pluginsURL),
                  let configurationURL,
                  let javaDebugURL,
                  javaTestBundleURLs.contains(where: {
                      $0.lastPathComponent.hasPrefix(Self.javaTestBundlePrefix)
                  }),
                  fileManager.fileExists(atPath: lombokURL.path) else {
                continue
            }
            return JDTLSLaunchResources(
                launcherJarURL: launcherURL,
                configurationDirectoryURL: configurationURL,
                lombokAgentURL: lombokURL,
                javaDebugBundleURL: javaDebugURL,
                javaExtensionBundleURLs: javaTestBundleURLs
            )
        }
        throw ResolutionError.incompleteInstallation
    }

    private func installationRoots(for executableURL: URL) -> [URL] {
        let executableURL = executableURL.standardizedFileURL
        var roots = [installationRoot(for: executableURL)]
        let resolvedURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = installationRoot(for: resolvedURL)
        if !roots.contains(resolvedRoot) { roots.append(resolvedRoot) }
        return roots
    }

    private func installationRoot(for executableURL: URL) -> URL {
        let directoryURL = executableURL.deletingLastPathComponent()
        return directoryURL.lastPathComponent == "bin"
            ? directoryURL.deletingLastPathComponent()
            : directoryURL
    }

    private func configurationDirectory(in rootURL: URL) -> URL? {
        #if arch(arm64)
        let configurationName = "config_mac_arm"
        #elseif arch(x86_64)
        let configurationName = "config_mac"
        #else
        return nil
        #endif
        let configuration = rootURL.appendingPathComponent(configurationName, isDirectory: true)
        return isDirectory(configuration) ? configuration : nil
    }

    private func firstEquinoxLauncher(in pluginsURL: URL) throws -> URL? {
        try firstRegularFile(
            in: pluginsURL,
            prefix: Self.equinoxLauncherPrefix,
            suffix: ".jar"
        )
    }

    private func firstJavaDebugBundle(in directoryURL: URL) throws -> URL? {
        try firstRegularFile(
            in: directoryURL,
            prefix: Self.javaDebugBundlePrefix,
            suffix: ".jar"
        )
    }

    private func firstRegularFile(
        in directoryURL: URL,
        prefix: String,
        suffix: String
    ) throws -> URL? {
        try regularFiles(in: directoryURL, prefix: prefix, suffix: suffix).first
    }

    private func javaTestExtensionBundles(in directoryURL: URL) throws -> [URL] {
        try regularFiles(in: directoryURL, prefix: "", suffix: ".jar")
    }

    private func regularFiles(
        in directoryURL: URL,
        prefix: String,
        suffix: String
    ) throws -> [URL] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try entries
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
                return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isBundled(_ executableURL: URL) -> Bool {
        guard let bundledJdtlsRootURL else { return false }
        let rootPath = bundledJdtlsRootURL.path + "/"
        return executableURL.standardizedFileURL.path.hasPrefix(rootPath)
    }

    private enum ResolutionError: LocalizedError {
        case incompleteInstallation

        var errorDescription: String? {
            "Expected an Equinox launcher JAR, a macOS configuration directory, "
                + "lombok/lombok.jar, and the Java Debug and Java Test extension bundles "
                + "in the selected JDTLS installation."
        }
    }
}
