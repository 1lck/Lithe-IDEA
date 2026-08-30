import Foundation
import LitheCoreContracts

enum DebugLaunchConfigurationResolutionError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case javaLaunchTargetUnavailable
    case invalidJavaAttachHost
    case invalidJavaAttachPort
    case noRustBinaryConfiguration
    case rustExecutableNotBuilt(URL, binary: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "The \(provider) Debug Adapter is not installed yet."
        case .javaLaunchTargetUnavailable:
            return "The Java language service could not resolve a main class for this file."
        case .invalidJavaAttachHost:
            return "Enter the host name of the running JVM."
        case .invalidJavaAttachPort:
            return "Enter a JVM debug port between 1 and 65535."
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
    private let javaTestLaunchResolver: (any JavaTestDebugLaunchResolving)?

    init(
        fileStorage: any FileStorage,
        executableSuffix: String = "",
        javaTestLaunchResolver: (any JavaTestDebugLaunchResolving)? = nil
    ) {
        self.fileExists = { fileStorage.fileExists(at: $0) }
        self.executableSuffix = executableSuffix
        self.javaTestLaunchResolver = javaTestLaunchResolver
    }

    init(
        executableSuffix: String = "",
        fileExists: @escaping (URL) -> Bool,
        javaTestLaunchResolver: (any JavaTestDebugLaunchResolving)? = nil
    ) {
        self.fileExists = fileExists
        self.executableSuffix = executableSuffix
        self.javaTestLaunchResolver = javaTestLaunchResolver
    }

    @MainActor
    func resolveJavaTest(
        target: JavaTestDebugLaunchTarget,
        resultPort: UInt16
    ) throws -> DebugLaunchConfiguration {
        guard let javaTestLaunchResolver else {
            throw DebugLaunchConfigurationResolutionError.javaLaunchTargetUnavailable
        }
        return try javaTestLaunchResolver.resolveJavaTestDebugLaunch(
            target: target,
            resultPort: resultPort
        )
    }

    func resolve(
        provider: LanguageProviderDescriptor,
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        javaTarget: JavaDebugLaunchTarget? = nil,
        options: (RunConfiguration) -> RunOptions
    ) throws -> DebugLaunchConfiguration {
        switch provider.id {
        case "java":
            guard let javaTarget else {
                throw DebugLaunchConfigurationResolutionError.javaLaunchTargetUnavailable
            }
            return javaConfiguration(
                documentURL: documentURL,
                workspaceURL: workspaceURL,
                configurations: configurations,
                selectedConfiguration: selectedConfiguration,
                target: javaTarget,
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

    func resolveJavaAttach(host: String, port: Int) throws -> DebugLaunchConfiguration {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw DebugLaunchConfigurationResolutionError.invalidJavaAttachHost
        }
        guard (1...65_535).contains(port) else {
            throw DebugLaunchConfigurationResolutionError.invalidJavaAttachPort
        }
        return DebugLaunchConfiguration(
            name: "\(normalizedHost):\(port)",
            request: .attach,
            arguments: [
                "hostName": .string(normalizedHost),
                "port": .integer(port)
            ]
        )
    }

    private func javaConfiguration(
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        target: JavaDebugLaunchTarget,
        options: (RunConfiguration) -> RunOptions
    ) -> DebugLaunchConfiguration {
        // Debug is a second execution mode for the selected Run configuration.
        // Keep every Java configuration eligible here so its JDK, Maven,
        // working-directory, VM/program arguments, profiles, and environment
        // overrides are carried over unchanged.
        let configuration = selectedConfiguration.flatMap { selected in
            selected.kind.providerID == "java" || selected.kind.isMavenBacked ? selected : nil
        }
        let runOptions = configuration.map(options)
        let mainClass = configuration?.mainClass ?? target.mainClass
        let configuredWorkingDirectory = runOptions?.workingDirectoryPath
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workingDirectory: String
        if configuredWorkingDirectory.isEmpty {
            workingDirectory = workspaceURL.standardizedFileURL.path
        } else {
            workingDirectory = URL(
                fileURLWithPath: configuredWorkingDirectory,
                relativeTo: workspaceURL
            ).standardizedFileURL.path
        }
        var arguments: [String: ToolingJSONValue] = [
            "mainClass": .string(mainClass),
            "cwd": .string(workingDirectory),
            "console": .string("integratedTerminal")
        ]
        if let projectName = target.projectName {
            arguments["projectName"] = .string(projectName)
        }
        if !target.modulePaths.isEmpty {
            arguments["modulePaths"] = .array(target.modulePaths.map(ToolingJSONValue.string))
        }
        if !target.classPaths.isEmpty {
            arguments["classPaths"] = .array(target.classPaths.map(ToolingJSONValue.string))
        }
        if let runOptions {
            let programArguments = runOptions.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !programArguments.isEmpty {
                arguments["args"] = .string(programArguments)
            }
            if !runOptions.environment.isEmpty {
                arguments["env"] = .object(runOptions.environment.mapValues(ToolingJSONValue.string))
            }
            let vmArguments = runOptions.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !vmArguments.isEmpty {
                arguments["vmArgs"] = .string(vmArguments)
            }
        }
        return DebugLaunchConfiguration(
            name: configuration?.name ?? documentURL.lastPathComponent,
            request: .launch,
            arguments: arguments
        )
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
