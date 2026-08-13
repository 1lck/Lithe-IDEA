import Foundation

enum DebugLaunchConfigurationResolutionError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case noRustBinaryConfiguration
    case rustExecutableNotBuilt(URL, binary: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "The \(provider) Debug Adapter is not installed yet."
        case .noRustBinaryConfiguration:
            return "No Cargo binary run configuration matches this Rust file."
        case .rustExecutableNotBuilt(let url, let binary):
            return "Build the Rust binary first with `cargo build --bin \(binary)`. Expected executable: \(url.path)"
        }
    }
}

/// Maps an editor target and the language-neutral run model into adapter launch
/// arguments. It contains no process or UI code, so platform composition can
/// supply only the executable naming convention and file-system capability.
struct DebugLaunchConfigurationResolver {
    private let fileExists: (URL) -> Bool
    private let executableSuffix: String

    init(
        fileStorage: any FileStorage,
        executableSuffix: String = ""
    ) {
        self.fileExists = { fileStorage.fileExists(at: $0) }
        self.executableSuffix = executableSuffix
    }

    init(
        executableSuffix: String = "",
        fileExists: @escaping (URL) -> Bool
    ) {
        self.fileExists = fileExists
        self.executableSuffix = executableSuffix
    }

    func resolve(
        provider: LanguageProviderDescriptor,
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        options: (RunConfiguration) -> RunOptions
    ) throws -> DebugLaunchConfiguration {
        switch provider.id {
        case "java":
            return javaConfiguration(
                documentURL: documentURL,
                workspaceURL: workspaceURL,
                configurations: configurations,
                selectedConfiguration: selectedConfiguration,
                options: options
            )
        case "python":
            return DebugLaunchConfiguration(
                name: documentURL.lastPathComponent,
                request: .launch,
                arguments: [
                    "program": .string(documentURL.standardizedFileURL.path),
                    "console": .string("internalConsole"),
                    "justMyCode": .bool(true)
                ]
            )
        case "rust":
            return try rustConfiguration(
                documentURL: documentURL,
                workspaceURL: workspaceURL,
                configurations: configurations,
                selectedConfiguration: selectedConfiguration,
                options: options
            )
        case "go":
            return goConfiguration(
                documentURL: documentURL,
                workspaceURL: workspaceURL,
                configurations: configurations,
                selectedConfiguration: selectedConfiguration
            )
        case "node":
            return nodeConfiguration(
                documentURL: documentURL,
                workspaceURL: workspaceURL,
                configurations: configurations,
                selectedConfiguration: selectedConfiguration,
                options: options
            )
        default:
            throw DebugLaunchConfigurationResolutionError.unsupportedProvider(provider.displayName)
        }
    }

    private func javaConfiguration(
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        options: (RunConfiguration) -> RunOptions
    ) -> DebugLaunchConfiguration {
        let configuration = selectedConfiguration.flatMap { selected in
            selected.kind.isMavenBacked ? selected : nil
        }
        var arguments: [String: ToolingJSONValue] = [
            "mainClass": .string(inferJavaMainClass(documentURL: documentURL, workspaceURL: workspaceURL)),
            "cwd": .string(workspaceURL.standardizedFileURL.path),
            "console": .string("internalConsole")
        ]
        if let configuration {
            let runOptions = options(configuration)
            let programArguments = RunArgumentParser.parse(runOptions.arguments)
            if !programArguments.isEmpty {
                arguments["args"] = .array(programArguments.map(ToolingJSONValue.string))
            }
            if !runOptions.environment.isEmpty {
                arguments["env"] = .object(runOptions.environment.mapValues(ToolingJSONValue.string))
            }
            let vmArguments = RunArgumentParser.parse(runOptions.vmArguments)
            if !vmArguments.isEmpty {
                arguments["vmArgs"] = .array(vmArguments.map(ToolingJSONValue.string))
            }
            if let modulePath = configuration.modulePath, !modulePath.isEmpty {
                arguments["projectName"] = .string(modulePath)
            }
        }
        return DebugLaunchConfiguration(
            name: configuration?.name ?? documentURL.lastPathComponent,
            request: .launch,
            arguments: arguments
        )
    }

    private func inferJavaMainClass(documentURL: URL, workspaceURL: URL) -> String {
        let file = documentURL.standardizedFileURL
        let root = workspaceURL.standardizedFileURL
        let relative = file.path.hasPrefix(root.path + "/")
            ? String(file.path.dropFirst(root.path.count + 1))
            : file.lastPathComponent
        let components = relative.split(separator: "/").map(String.init)
        let sourceRoots = ["src/main/java", "src/test/java", "src/main/kotlin"]
        let sourceRootIndex: Int? = sourceRoots.compactMap { sourceRoot -> Int? in
            let rootComponents = sourceRoot.split(separator: "/").map(String.init)
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }
            return rootComponents.count
        }.first
        let classComponents = Array(components.dropFirst(sourceRootIndex ?? max(0, components.count - 1)))
        let className = classComponents.joined(separator: ".")
            .replacingOccurrences(of: ".java", with: "")
        return className.isEmpty ? file.deletingPathExtension().lastPathComponent : className
    }

    private func nodeConfiguration(
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        options: (RunConfiguration) -> RunOptions
    ) -> DebugLaunchConfiguration {
        let nodeConfigurations = configurations.filter {
            $0.kind.providerID == "npm"
        }
        let configuration: RunConfiguration?
        if let selectedConfiguration, selectedConfiguration.kind.providerID == "npm" {
            configuration = selectedConfiguration
        } else {
            configuration = nodeConfigurations
                .filter { contains(documentURL, inModule: $0.modulePath, workspaceURL: workspaceURL) }
                .max { moduleDepth($0.modulePath) < moduleDepth($1.modulePath) }
        }
        let moduleURL = workspaceURL
            .appendingPathComponent(configuration?.modulePath ?? "", isDirectory: true)
            .standardizedFileURL
        var arguments: [String: ToolingJSONValue] = [
            "type": .string("pwa-node"),
            "cwd": .string(moduleURL.path),
            "console": .string("internalConsole"),
            "skipFiles": .array([.string("<node_internals>/**")])
        ]
        if let configuration {
            let runOptions = options(configuration)
            arguments["runtimeExecutable"] = .string("npm")
            arguments["runtimeArgs"] = .array([
                .string("run"),
                .string(configuration.name)
            ])
            let programArguments = RunArgumentParser.parse(runOptions.arguments)
            if !programArguments.isEmpty {
                arguments["args"] = .array(programArguments.map(ToolingJSONValue.string))
            }
            if !runOptions.environment.isEmpty {
                arguments["env"] = .object(runOptions.environment.mapValues(ToolingJSONValue.string))
            }
        } else {
            arguments["program"] = .string(documentURL.standardizedFileURL.path)
        }
        return DebugLaunchConfiguration(
            name: configuration?.name ?? documentURL.lastPathComponent,
            request: .launch,
            arguments: arguments
        )
    }

    private func goConfiguration(
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?
    ) -> DebugLaunchConfiguration {
        let goConfigurations = configurations.filter {
            $0.kind.providerID == "go" && $0.execution == .application
        }
        let configuration: RunConfiguration?
        if let selectedConfiguration,
           selectedConfiguration.kind.providerID == "go",
           selectedConfiguration.execution == .application {
            configuration = selectedConfiguration
        } else {
            configuration = goConfigurations
                .filter { contains(documentURL, inModule: $0.modulePath, workspaceURL: workspaceURL) }
                .max { moduleDepth($0.modulePath) < moduleDepth($1.modulePath) }
        }
        let programURL: URL
        if let modulePath = configuration?.modulePath, !modulePath.isEmpty {
            programURL = workspaceURL.appendingPathComponent(modulePath, isDirectory: true)
        } else {
            programURL = documentURL.deletingLastPathComponent()
        }
        let normalizedProgram = programURL.standardizedFileURL
        return DebugLaunchConfiguration(
            name: configuration?.name ?? documentURL.lastPathComponent,
            request: .launch,
            arguments: [
                "mode": .string("debug"),
                "program": .string(normalizedProgram.path),
                "cwd": .string(normalizedProgram.path),
                "stopOnEntry": .bool(false)
            ]
        )
    }

    private func rustConfiguration(
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        options: (RunConfiguration) -> RunOptions
    ) throws -> DebugLaunchConfiguration {
        let cargoConfigurations = configurations.filter {
            $0.kind.providerID == "cargo" && $0.execution == .application
        }
        let configuration: RunConfiguration?
        if let selectedConfiguration,
           selectedConfiguration.kind.providerID == "cargo",
           selectedConfiguration.execution == .application {
            configuration = selectedConfiguration
        } else {
            configuration = cargoConfigurations
                .filter { contains(documentURL, inModule: $0.modulePath, workspaceURL: workspaceURL) }
                .max { moduleDepth($0.modulePath) < moduleDepth($1.modulePath) }
                ?? cargoConfigurations.first
        }
        guard let configuration else {
            throw DebugLaunchConfigurationResolutionError.noRustBinaryConfiguration
        }

        let moduleURL = workspaceURL
            .appendingPathComponent(configuration.modulePath ?? "", isDirectory: true)
            .standardizedFileURL
        let runOptions = options(configuration)
        let targetRoot: URL
        if let configured = runOptions.environment["CARGO_TARGET_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            if configured.hasPrefix("/") {
                targetRoot = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                targetRoot = moduleURL.appendingPathComponent(configured, isDirectory: true)
            }
        } else {
            targetRoot = moduleURL.appendingPathComponent("target", isDirectory: true)
        }
        let executableURL = targetRoot
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent(configuration.name + executableSuffix)
            .standardizedFileURL
        guard fileExists(executableURL) else {
            throw DebugLaunchConfigurationResolutionError.rustExecutableNotBuilt(
                executableURL,
                binary: configuration.name
            )
        }
        return DebugLaunchConfiguration(
            name: configuration.name,
            request: .launch,
            arguments: [
                "program": .string(executableURL.path),
                "cwd": .string(moduleURL.path),
                "stopOnEntry": .bool(false)
            ]
        )
    }

    private func contains(_ fileURL: URL, inModule modulePath: String?, workspaceURL: URL) -> Bool {
        let moduleURL = workspaceURL
            .appendingPathComponent(modulePath ?? "", isDirectory: true)
            .standardizedFileURL
        let filePath = fileURL.standardizedFileURL.path
        return filePath == moduleURL.path || filePath.hasPrefix(moduleURL.path + "/")
    }

    private func moduleDepth(_ modulePath: String?) -> Int {
        (modulePath ?? "").split(separator: "/").count
    }

}
