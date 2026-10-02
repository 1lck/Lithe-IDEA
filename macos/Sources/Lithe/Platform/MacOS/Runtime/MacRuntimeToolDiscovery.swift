import Foundation

/// macOS-only tool discovery.  It is deliberately a read-only adapter: it
/// checks known locations and environment variables but never invokes a
/// package manager or installs anything on the user's behalf.
struct MacRuntimeToolDiscovery: RuntimeToolDiscovery {
    private let resourceDirectoryURL: URL?
    private let pluginToolRoots: [URL]
    private let configuredPluginExecutablesProvider: @Sendable () -> [String: [URL]]
    private let isExecutable: @Sendable (URL) -> Bool

    init(
        resourceDirectoryURL: URL? = Bundle.main.resourceURL,
        pluginToolRoots: [URL] = [],
        configuredPluginExecutablesProvider: @escaping @Sendable () -> [String: [URL]] = { [:] },
        isExecutable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.resourceDirectoryURL = resourceDirectoryURL?.standardizedFileURL
        self.pluginToolRoots = pluginToolRoots.map(\.standardizedFileURL)
        self.configuredPluginExecutablesProvider = configuredPluginExecutablesProvider
        self.isExecutable = isExecutable
    }

    func candidates(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> [RuntimeToolCandidate] {
        guard !command.isEmpty, !command.contains("/") else { return [] }
        var result: [RuntimeToolCandidate] = []
        var seen = Set<String>()

        func add(_ url: URL, source: RuntimeToolSource, detail: String? = nil) {
            let normalized = url.standardizedFileURL
            guard isExecutable(normalized),
                  seen.insert(normalized.path).inserted else { return }
            result.append(RuntimeToolCandidate(
                command: command,
                executableURL: normalized,
                source: source,
                detail: detail
            ))
        }

        if command == "jdtls", let resourceDirectoryURL {
            add(
                resourceDirectoryURL.appendingPathComponent("LanguageServers/jdtls/bin/jdtls"),
                source: .bundled,
                detail: "Bundled with Lithe"
            )
        }

        if command == "intelephense" {
            for root in pluginToolRoots {
                add(
                    root.appendingPathComponent("bin/intelephense"),
                    source: .bundled,
                    detail: "PHP Support plugin"
                )
            }
        }

        // Project-local toolchains are preferred because they are reproducible
        // and do not alter the user's global environment.
        if let projectURL {
            let root = projectURL.standardizedFileURL
            for relativePath in [
                ".lithe/toolchains/bin/\(command)",
                ".lithe/toolchains/\(command)",
                ".lithe/bin/\(command)"
            ] {
                add(root.appendingPathComponent(relativePath), source: .project, detail: relativePath)
            }
        }

        // An explicit per-tool override is useful for adapters distributed as
        // an archive or a standalone script.  It is still only inspected.
        for key in environmentKeys(for: command) {
            if let configured = environment[key],
               let url = configuredURL(configured, projectURL: projectURL) {
                add(url, source: .custom, detail: key)
            }
        }

        for executable in configuredPluginExecutablesProvider()[command] ?? [] {
            add(
                executable,
                source: .bundled,
                detail: "Configured plugin toolchain"
            )
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let path = String(directory)
            let source: RuntimeToolSource = isHomebrewPath(path) ? .homebrew : .path
            add(
                URL(fileURLWithPath: path).appendingPathComponent(command),
                source: source,
                detail: source == .homebrew ? "PATH/Homebrew: \(path)" : "PATH: \(path)"
            )
        }

        let homebrewRoots = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/\(homebrewFormula(for: command))/bin",
            "/usr/local/opt/\(homebrewFormula(for: command))/bin"
        ]
        for root in homebrewRoots {
            add(
                URL(fileURLWithPath: root).appendingPathComponent(command),
                source: .homebrew,
                detail: root
            )
        }

        // Xcode and Command Line Tools may expose lldb-dap through xcrun even
        // when the GUI application's PATH does not include Developer/bin.
        if command == "lldb-dap" {
            for url in [
                "/usr/bin/lldb-dap",
                "/Library/Developer/CommandLineTools/usr/bin/lldb-dap",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap"
            ].map(URL.init(fileURLWithPath:)) {
                add(url, source: .xcode, detail: "Xcode toolchain")
            }
        }
        if command == "xcrun" {
            add(URL(fileURLWithPath: "/usr/bin/xcrun"), source: .xcode, detail: "Xcode toolchain lookup")
        }

        for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            add(
                URL(fileURLWithPath: directory).appendingPathComponent(command),
                source: .system,
                detail: directory
            )
        }
        return result
    }

    func guidance(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> RuntimeToolGuidance {
        switch command {
        case "python", "python3":
            return RuntimeToolGuidance(
                command: command,
                displayName: "Python toolchain",
                summary: "Python tooling (\(command)) was not found.",
                recovery: "Select a Python interpreter or virtual environment, install the provider there, and ensure its bin directory is on PATH."
            )
        case "node", "npm", "npx", "tsx", "ts-node":
            return RuntimeToolGuidance(
                command: command,
                displayName: "Node.js toolchain",
                summary: "Node.js tooling (\(command)) was not found.",
                recovery: "Install Node.js and the required npm package, then restart Lithe or add the Node bin directory to PATH."
            )
        case "cargo", "rustc", "lldb-dap":
            return RuntimeToolGuidance(
                command: command,
                displayName: "Rust/Xcode toolchain",
                summary: "Rust or debugger tooling (\(command)) was not found.",
                recovery: command == "lldb-dap"
                    ? "Install or select Xcode Command Line Tools, or configure an lldb-dap path explicitly."
                    : "Install Rust with rustup and ensure Cargo's bin directory is on PATH."
            )
        case "java-debug-adapter", "java-debug":
            return RuntimeToolGuidance(
                command: command,
                displayName: "Java Debug Adapter",
                summary: "A Java DAP adapter was not found.",
                recovery: "Reinstall Lithe's bundled Java language and Debug Adapter resources."
            )
        case "intelephense":
            return RuntimeToolGuidance(
                command: command,
                displayName: "PHP language server",
                summary: "Intelephense was not found in the PHP Support plugin or configured toolchain.",
                recovery: "Reinstall PHP Support from Plugin Management, or install Node.js and configure an Intelephense executable."
            )
        default:
            return RuntimeToolGuidance(
                command: command,
                summary: "\(command) was not found in the configured toolchain.",
                recovery: "Add its executable directory to PATH or configure a project-local toolchain."
            )
        }
    }

    private func configuredURL(_ value: String, projectURL: URL?) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        return projectURL?.appendingPathComponent(trimmed)
    }

    private func environmentKeys(for command: String) -> [String] {
        let normalized = command
            .uppercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let suffix = String(normalized)
        return ["LITHE_\(suffix)_PATH", "LITHE_TOOL_\(suffix)_PATH"]
    }

    private func homebrewFormula(for command: String) -> String {
        switch command {
        case "tsx": "tsx"
        case "ts-node": "ts-node"
        case "cargo", "rustc": "rust"
        case "clangd": "llvm"
        case "lldb-dap": "llvm"
        default: command
        }
    }

    private func isHomebrewPath(_ path: String) -> Bool {
        path == "/opt/homebrew/bin"
            || path == "/usr/local/bin"
            || path.hasPrefix("/opt/homebrew/opt/")
            || path.hasPrefix("/usr/local/opt/")
    }

}
