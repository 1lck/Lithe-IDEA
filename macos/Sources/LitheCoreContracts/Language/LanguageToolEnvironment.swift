import Foundation

/// Environment variables a language-server process receives for the runtime
/// tools it depends on.
package enum LanguageToolEnvironment {
    /// `LITHE_<TOOL>_PATH`, which launchers read to find a discovered tool.
    package static func runtimeToolKey(_ tool: String) -> String {
        let name = String(tool.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return "LITHE_\(name)_PATH"
    }

    /// Exports `executableURL` as the runtime `tool` and puts its directory
    /// first on `PATH`. The host selected this exact file, so a helper the
    /// server starts by command name, for example through `/usr/bin/env node`,
    /// runs on the same runtime instead of whichever one the inherited `PATH`
    /// happens to contain.
    package static func exportingRuntime(
        tool: String,
        executableURL: URL,
        into environment: [String: String]
    ) -> [String: String] {
        var environment = environment
        environment[runtimeToolKey(tool)] = executableURL.path
        let directory = executableURL.deletingLastPathComponent().path
        let remaining = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0 != directory }
        environment["PATH"] = ([directory] + remaining).joined(separator: ":")
        return environment
    }
}
