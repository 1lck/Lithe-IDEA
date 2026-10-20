import Foundation

/// macOS-only tool discovery.  It is deliberately a read-only adapter: it
/// checks known locations and environment variables but never invokes a
/// package manager or installs anything on the user's behalf.
struct MacRuntimeToolDiscovery: RuntimeToolDiscovery {
    private let homeDirectoryURL: URL
    private let isExecutable: @Sendable (URL) -> Bool
    private let directoryNames: @Sendable (URL) -> [String]

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        },
        directoryNames: @escaping @Sendable (URL) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
    ) {
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.isExecutable = isExecutable
        self.directoryNames = directoryNames
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

        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let path = String(directory)
            let source: RuntimeToolSource = isHomebrewPath(path) ? .homebrew : .path
            add(
                URL(fileURLWithPath: path).appendingPathComponent(command),
                source: source,
                detail: source == .homebrew ? "PATH/Homebrew: \(path)" : "PATH: \(path)"
            )
        }

        if shouldSearchGoUserBin(for: command) {
            for directory in goUserBinDirectories(environment: environment) {
                add(
                    directory.appendingPathComponent(command),
                    source: .environment,
                    detail: "Go user bin: \(directory.path)"
                )
            }
        }

        if command == "node" {
            for directory in nodeVersionManagerDirectories() {
                add(
                    directory.appendingPathComponent(command),
                    source: .environment,
                    detail: "Node version manager: \(directory.path)"
                )
            }
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
        case "go", "dlv":
            return RuntimeToolGuidance(
                command: command,
                displayName: "Go toolchain",
                summary: "Go tooling (\(command)) was not found.",
                recovery: "Install Go, then install the missing tool with `go install` or add its bin directory to PATH."
            )
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
                summary: "Intelephense was not found on PATH or in the configured toolchain.",
                // PHP Support does not bundle Intelephense: its licence does not
                // allow redistribution, so the user installs it.
                recovery: "Install Node.js, then run npm install -g intelephense and restart the language server."
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
        case "dlv": "delve"
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

    private func goUserBinDirectories(environment: [String: String]) -> [URL] {
        var directories: [URL] = []
        if let goBin = configuredURL(environment["GOBIN"] ?? "", projectURL: nil) {
            directories.append(goBin)
        }
        for goPath in (environment["GOPATH"] ?? "").split(separator: ":") where !goPath.isEmpty {
            directories.append(URL(fileURLWithPath: String(goPath)).appendingPathComponent("bin"))
        }
        directories.append(homeDirectoryURL.appendingPathComponent("go/bin"))
        directories.append(homeDirectoryURL.appendingPathComponent(".go/bin"))
        return directories
    }

    /// GUI apps do not run shell init files, so Node installed through a
    /// version manager is only found through these well-known locations.
    /// nvm installs are ordered newest first to keep the choice deterministic.
    private func nodeVersionManagerDirectories() -> [URL] {
        var directories = [
            homeDirectoryURL.appendingPathComponent(".volta/bin"),
            homeDirectoryURL.appendingPathComponent("Library/Application Support/fnm/aliases/default/bin"),
            homeDirectoryURL.appendingPathComponent(".local/share/fnm/aliases/default/bin")
        ]
        let nvmVersions = homeDirectoryURL.appendingPathComponent(".nvm/versions/node")
        let versions = directoryNames(nvmVersions)
            .compactMap { name -> (name: String, components: [Int])? in
                guard name.hasPrefix("v") else { return nil }
                let components = name.dropFirst().split(separator: ".").map { Int($0) }
                guard !components.isEmpty, components.allSatisfy({ $0 != nil }) else { return nil }
                return (name, components.compactMap { $0 })
            }
            .sorted { $0.components.lexicographicallyPrecedes($1.components) }
            .reversed()
        directories += versions.map {
            nvmVersions.appendingPathComponent($0.name).appendingPathComponent("bin")
        }
        return directories
    }

    private func shouldSearchGoUserBin(for command: String) -> Bool {
        switch command {
        case "dlv", "gofumpt", "goimports", "gomodifytags", "gopls", "staticcheck":
            return true
        default:
            return false
        }
    }
}
