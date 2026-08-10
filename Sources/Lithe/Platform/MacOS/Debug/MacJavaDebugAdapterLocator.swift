import Foundation

struct JavaDebugAdapterProcessLaunch: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

/// Locates an optional stdio Java DAP adapter without installing or starting
/// it.  Java's JDB integration remains the fallback when this adapter is not
/// present, so a clean machine keeps the existing debugging workflow.
struct MacJavaDebugAdapterLocator {
    private let environment: [String: String]
    private let homeDirectoryURL: URL
    private let launchDefinition: StdioDebugAdapterLaunch?

    init(
        environment: [String: String],
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchDefinition: StdioDebugAdapterLaunch? = nil
    ) {
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.launchDefinition = launchDefinition
    }

    func resolve(
        rootURL: URL,
        javaExecutableURL: URL?
    ) -> JavaDebugAdapterProcessLaunch? {
        let configured = environment["LITHE_JAVA_DEBUG_PATH"]
            .flatMap { configuredURL($0, relativeTo: rootURL) }
        let roots = [
            configured,
            rootURL.appendingPathComponent(".lithe/toolchains/java-debug", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("Library/Application Support/Lithe/java-debug", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".local/share/lithe/java-debug", isDirectory: true)
        ].compactMap { $0 }

        for root in roots {
            if let launch = launch(for: root, javaExecutableURL: javaExecutableURL) {
                return launch
            }
        }

        for command in launchDefinition?.executableNames
            ?? ["java-debug-adapter", "java-debug", "jdtls-debug"] {
            if let executable = executableOnPath(command) {
                return JavaDebugAdapterProcessLaunch(
                    executableURL: executable,
                    arguments: arguments(for: executable, defaultArguments: launchDefinition?.arguments ?? []),
                    environment: environment
                )
            }
        }
        return nil
    }

    var unavailableMessage: String {
        "Java generic debugging requires a stdio Debug Adapter. Set LITHE_JAVA_DEBUG_PATH to the adapter executable or JAR; JDB remains available as the fallback."
    }

    private func launch(
        for candidate: URL,
        javaExecutableURL: URL?
    ) -> JavaDebugAdapterProcessLaunch? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            let names = (launchDefinition?.executableNames ?? [
                "java-debug-adapter",
                "java-debug",
                "jdtls-debug",
                "java-debug-adapter.jar",
                "java-debug-server.jar"
            ]) + ["java-debug-adapter.jar", "java-debug-server.jar"]
            for name in names {
                if let launch = launch(
                    for: candidate.appendingPathComponent(name),
                    javaExecutableURL: javaExecutableURL
                ) {
                    return launch
                }
            }
            return nil
        }

        if candidate.pathExtension.lowercased() == "jar" {
            guard let javaExecutableURL else { return nil }
            return JavaDebugAdapterProcessLaunch(
                executableURL: javaExecutableURL,
                arguments: arguments(
                    for: candidate,
                    defaultArguments: ["-jar", candidate.path] + (launchDefinition?.arguments ?? ["--stdio"])
                ),
                environment: environment
            )
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return JavaDebugAdapterProcessLaunch(
            executableURL: candidate,
            arguments: arguments(for: candidate, defaultArguments: launchDefinition?.arguments ?? []),
            environment: environment
        )
    }

    private func arguments(for _: URL, defaultArguments: [String]) -> [String] {
        guard let raw = environment["LITHE_JAVA_DEBUG_ARGS"] else { return defaultArguments }
        return RunArgumentParser.parse(raw)
    }

    private func executableOnPath(_ command: String) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(command)
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func configuredURL(_ value: String, relativeTo rootURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        return rootURL.appendingPathComponent(trimmed)
    }
}
