import Foundation
import CryptoKit
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
    private static let javaTestRunnerName = "com.microsoft.java.test.runner-jar-with-dependencies.jar"

    private let bundledJdtlsRootURL: URL?
    private let bundledAppRootURL: URL?
    private let configurationCacheDirectoryURL: URL?
    private let fileManager: FileManager

    init(
        bundledJdtlsRootURL: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("LanguageServers/jdtls", isDirectory: true),
        bundledAppRootURL: URL? = Bundle.main.bundleURL,
        configurationCacheDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.bundledJdtlsRootURL = bundledJdtlsRootURL?.standardizedFileURL
        self.bundledAppRootURL = bundledAppRootURL?.standardizedFileURL
        self.configurationCacheDirectoryURL = configurationCacheDirectoryURL?.standardizedFileURL
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
            let bundledConfigurationURL = configurationDirectory(in: rootURL)
            let lombokURL = rootURL.appendingPathComponent("lombok/lombok.jar")
            let javaDebugURL = try firstJavaDebugBundle(
                in: rootURL.appendingPathComponent("java-debug", isDirectory: true)
            )
            let javaTestBundleURLs = try javaTestExtensionBundles(
                in: rootURL.appendingPathComponent("java-test/extensions", isDirectory: true)
            )
            let javaTestRunnerURL = rootURL
                .appendingPathComponent("java-test/runner", isDirectory: true)
                .appendingPathComponent(Self.javaTestRunnerName)
            guard let launcherURL = try firstEquinoxLauncher(in: pluginsURL),
                  let bundledConfigurationURL,
                  let javaDebugURL,
                  javaTestBundleURLs.contains(where: {
                      $0.lastPathComponent.hasPrefix(Self.javaTestBundlePrefix)
                  }),
                  fileManager.fileExists(atPath: javaTestRunnerURL.path),
                  fileManager.fileExists(atPath: lombokURL.path) else {
                continue
            }
            let configurationURL = try writableConfigurationDirectory(
                bundledConfigurationURL,
                in: rootURL
            )
            return JDTLSLaunchResources(
                launcherJarURL: launcherURL,
                configurationDirectoryURL: configurationURL,
                lombokAgentURL: lombokURL,
                javaDebugBundleURL: javaDebugURL,
                javaExtensionBundleURLs: javaTestBundleURLs,
                javaTestRunnerURL: javaTestRunnerURL
            )
        }
        throw ResolutionError.incompleteInstallation
    }

    /// JDT LS writes its OSGi state below the configuration directory. Keep
    /// that mutable state outside the signed app bundle so Sparkle deltas can
    /// still match the shipped application bytes.
    private func writableConfigurationDirectory(
        _ bundledConfigurationURL: URL,
        in installationRootURL: URL
    ) throws -> URL {
        guard let configurationCacheDirectoryURL,
              isBundled(installationRootURL) else {
            return bundledConfigurationURL
        }
        let configurationName = bundledConfigurationURL.lastPathComponent
        let sourceConfigURL = bundledConfigurationURL.appendingPathComponent("config.ini")
        let digest = SHA256.hash(data: try Data(contentsOf: sourceConfigURL))
            .map { String(format: "%02x", $0) }
            .joined()
        let cacheRoot = configurationCacheDirectoryURL
            .appendingPathComponent("jdtls/configurations", isDirectory: true)
        let cachedConfigurationURL = cacheRoot
            .appendingPathComponent("\(configurationName)-\(digest)", isDirectory: true)
        guard cacheDirectoryIsOutsideBundle(
            configurationCacheDirectoryURL,
            cacheRoot,
            cachedConfigurationURL
        ) else { throw ResolutionError.invalidConfigurationCache }
        if isDirectory(cachedConfigurationURL),
           fileManager.fileExists(
               atPath: cachedConfigurationURL.appendingPathComponent("config.ini").path
           ) {
            return cachedConfigurationURL
        }
        guard !fileManager.fileExists(atPath: cachedConfigurationURL.path) else {
            throw ResolutionError.incompleteConfigurationCache
        }

        try fileManager.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        guard cacheDirectoryIsOutsideBundle(cacheRoot, cachedConfigurationURL) else {
            throw ResolutionError.invalidConfigurationCache
        }
        let stagingURL = cacheRoot.appendingPathComponent(
            ".\(configurationName)-\(UUID().uuidString)",
            isDirectory: true
        )
        guard cacheDirectoryIsOutsideBundle(stagingURL) else {
            throw ResolutionError.invalidConfigurationCache
        }
        do {
            try fileManager.copyItem(at: bundledConfigurationURL, to: stagingURL)
            guard cacheDirectoryIsOutsideBundle(stagingURL, cachedConfigurationURL) else {
                throw ResolutionError.invalidConfigurationCache
            }
            do {
                try fileManager.moveItem(at: stagingURL, to: cachedConfigurationURL)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Accept a concurrent publisher only after validating its result.
                guard isDirectory(cachedConfigurationURL),
                      fileManager.fileExists(
                          atPath: cachedConfigurationURL.appendingPathComponent("config.ini").path
                      ) else {
                    throw ResolutionError.incompleteConfigurationCache
                }
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        if fileManager.fileExists(atPath: stagingURL.path) {
            try? fileManager.removeItem(at: stagingURL)
        }
        guard cacheDirectoryIsOutsideBundle(cachedConfigurationURL) else {
            throw ResolutionError.invalidConfigurationCache
        }
        return cachedConfigurationURL
    }

    private func cacheDirectoryIsOutsideBundle(_ urls: URL...) -> Bool {
        guard let bundledAppRootURL else { return false }
        let bundleRootPath = bundledAppRootURL.standardizedFileURL.path
        let bundleResolvedRootPath = bundledAppRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        for url in urls {
            let paths = [
                url.standardizedFileURL.path,
                url.resolvingSymlinksInPath().standardizedFileURL.path,
            ]
            guard paths.allSatisfy({ path in
                !isPath(path, inside: bundleRootPath)
                    && !isPath(path, inside: bundleResolvedRootPath)
            }) else { return false }
        }
        return true
    }

    private func isPath(_ path: String, inside rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
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

    private func isBundled(_ url: URL) -> Bool {
        guard let bundledJdtlsRootURL else { return false }
        let rootPath = bundledJdtlsRootURL.standardizedFileURL.path
        let resolvedRootPath = bundledJdtlsRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let candidatePaths = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        return candidatePaths.contains { path in
            isPath(path, inside: rootPath) || isPath(path, inside: resolvedRootPath)
        }
    }

    private enum ResolutionError: LocalizedError {
        case incompleteInstallation
        case invalidConfigurationCache
        case incompleteConfigurationCache

        var errorDescription: String? {
            switch self {
            case .incompleteInstallation:
                return "Expected an Equinox launcher JAR, a macOS configuration directory, "
                    + "lombok/lombok.jar, Java Debug and Java Test extension bundles, and the TestNG runner "
                    + "in the selected JDTLS installation."
            case .invalidConfigurationCache:
                return "The JDTLS configuration cache must be outside the installed app bundle."
            case .incompleteConfigurationCache:
                return "The JDTLS configuration cache is incomplete. Remove the damaged cache and retry."
            }
        }
    }
}
