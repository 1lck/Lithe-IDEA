import Foundation

/// Discovers executable login shells without launching them or loading user scripts.
enum MacTerminalShellDiscovery {
    private static let shellNames = ["zsh", "bash", "fish", "nu", "pwsh", "sh", "dash", "ksh", "tcsh", "csh"]
    private static let standardSearchDirectories = ["/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    static func availableShells(fileManager: FileManager = .default) -> [String] {
        let registeredShells: String
        do {
            registeredShells = try String(contentsOfFile: "/etc/shells", encoding: .utf8)
        } catch {
            NSLog("Lithe could not read registered login shells: %@", String(describing: error))
            registeredShells = ""
        }
        return discover(
            environment: ProcessInfo.processInfo.environment,
            registeredShells: registeredShells
        ) { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
        }
    }

    static func discover(
        environment: [String: String],
        registeredShells: String,
        isExecutable: (String) -> Bool
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
            path.hasPrefix("/") && seen.insert(path).inserted && isExecutable(path)
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
