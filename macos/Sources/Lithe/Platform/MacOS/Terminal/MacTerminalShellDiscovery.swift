import Foundation

/// Discovers executable login shells without launching them or loading user scripts.
enum MacTerminalShellDiscovery {
    private static let shellNames = ["zsh", "bash", "fish", "nu", "pwsh", "sh", "dash", "ksh", "tcsh", "csh"]
    private static let standardSearchDirectories = ["/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    static func availableShells(fileManager: FileManager = .default) -> [String] {
        let registeredShells = registeredShells()
        return discover(
            environment: ProcessInfo.processInfo.environment,
            registeredShells: registeredShells
        ) { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
        }
    }

    /// Returns reasonable shell paths even when the executable is missing.
    /// Settings uses this list to show unavailable choices instead of hiding them.
    static func knownShells() -> [String] {
        candidates(
            environment: ProcessInfo.processInfo.environment,
            registeredShells: registeredShells()
        )
    }

    static func discover(
        environment: [String: String],
        registeredShells: String,
        isExecutable: (String) -> Bool
    ) -> [String] {
        candidates(environment: environment, registeredShells: registeredShells).filter(isExecutable)
    }

    static func candidates(
        environment: [String: String],
        registeredShells: String
    ) -> [String] {
        var candidates = [environment["SHELL"]].compactMap { $0 }
        candidates += registeredShells.split(whereSeparator: \.isNewline).compactMap { line in
            let path = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        let searchDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + standardSearchDirectories
        for directory in searchDirectories where directory.hasPrefix("/") {
            candidates += shellNames.map { URL(fileURLWithPath: directory).appendingPathComponent($0).path }
        }
        var seen = Set<String>()
        return candidates.filter { path in
            path.hasPrefix("/") && seen.insert(path).inserted
        }
    }

    private static func registeredShells() -> String {
        do {
            return try String(contentsOfFile: "/etc/shells", encoding: .utf8)
        } catch {
            NSLog("Lithe could not read registered login shells: %@", String(describing: error))
            return ""
        }
    }

    static func startupArguments(for shellPath: String) -> [String] {
        switch URL(fileURLWithPath: shellPath).lastPathComponent {
        case "pwsh": ["-NoLogo", "-Login"]
        case "nu": ["--login", "--interactive"]
        case "zsh", "bash", "fish", "sh", "dash", "ksh": ["-l", "-i"]
        case "csh", "tcsh": ["-l"]
        default: []
        }
    }
}
