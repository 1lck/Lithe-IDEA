import Foundation

enum MacProcessArchitecture: Sendable {
    case arm64
    case x86_64
    case unsupported

    static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unsupported
        #endif
    }

    var bundledJdkDirectoryName: String? {
        switch self {
        case .arm64: "jdk-arm64"
        case .x86_64: "jdk-x86_64"
        case .unsupported: nil
        }
    }
}

struct MacRuntimeLocator: RuntimeLocator {
    private let resourceURL: URL?
    private let processArchitecture: MacProcessArchitecture

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        processArchitecture: MacProcessArchitecture = .current
    ) {
        self.resourceURL = resourceURL
        self.processArchitecture = processArchitecture
    }

    func environment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    func discover() -> RuntimeDiscoveryResult {
        MacRuntimeDiscovery.discover(environment: environment())
    }

    func validJavaHome(path: String) -> URL? {
        MacRuntimeDiscovery.validJavaHome(path)
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        MacRuntimeDiscovery.probeJavaHome(homeURL)
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func systemMavenExecutable() -> URL? {
        MacRuntimeDiscovery.systemMavenExecutable(environment: environment())
    }

    func mavenExecutable(forHomePath path: String) -> URL? {
        MacRuntimeDiscovery.mavenExecutable(forHomePath: path)
    }

    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? {
        MacRuntimeDiscovery.probeMaven(executableURL)
    }

    /// Returns the bundled JDK matching the current process architecture.
    /// Universal apps carry separate runtimes because a JDK contains native
    /// libraries throughout its installation. Single-architecture and legacy
    /// bundles continue to use `LanguageServers/jdk`.
    func bundledJdkHome() -> URL? {
        guard let resourceURL else { return nil }
        let languageServers = resourceURL.appendingPathComponent(
            "LanguageServers",
            isDirectory: true
        )
        guard let architectureDirectory = processArchitecture.bundledJdkDirectoryName else {
            return nil
        }

        let architectureHome = languageServers
            .appendingPathComponent(architectureDirectory, isDirectory: true)
            .standardizedFileURL
        if isExecutableJava(in: architectureHome) {
            return architectureHome
        }

        // The presence of either suffixed directory marks the new universal
        // layout. Do not hide a missing runtime by falling back across layouts.
        let hasUniversalLayout = ["jdk-arm64", "jdk-x86_64"].contains { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: languageServers.appendingPathComponent(directory).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
        guard !hasUniversalLayout else { return nil }

        let legacyHome = languageServers
            .appendingPathComponent("jdk", isDirectory: true)
            .standardizedFileURL
        return isExecutableJava(in: legacyHome) ? legacyHome : nil
    }

    private func isExecutableJava(in home: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("bin/java").path)
    }
}
