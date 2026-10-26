import Foundation
import LitheModuleAPI
import LitheCoreContracts

enum DebugLaunchConfigurationResolutionError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case javaLaunchTargetUnavailable
    case invalidJavaAttachHost
    case invalidJavaAttachPort
    case javaRuntimeUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return L10n.string("The \(provider) Debug Adapter is not installed yet.")
        case .javaLaunchTargetUnavailable:
            return L10n.string("The Java language service could not resolve a main class for this file.")
        case .invalidJavaAttachHost:
            return L10n.string("Enter the host name of the running JVM.")
        case .invalidJavaAttachPort:
            return L10n.string("Enter a JVM debug port between 1 and 65535.")
        case .javaRuntimeUnavailable:
            return L10n.string("No Java runtime was found. Set JAVA_HOME or install a JDK.")
        }
    }
}

/// The JDK a debugged JVM runs on. Debug stores no JDK of its own: it names
/// the runtime Run uses for the same target, so changing one changes both.
enum DebugJavaRuntime: Equatable {
    /// A Java configuration's JDK; no override means the project JDK chain.
    case java(homeOverride: String?)
    /// The JDK Maven launches with, for Maven-backed configurations and tests.
    case maven(homeOverride: String?)

    /// The runtime Run would use for `configuration`; `nil` means a file
    /// debugged without a Run configuration.
    init(configuration: RunConfiguration?, options: RunOptions?) {
        let javaHome = options?.javaHomePath
        guard let configuration, configuration.kind.isMavenBacked else {
            self = .java(homeOverride: javaHome)
            return
        }
        let mavenHome = options?.mavenJavaHomePath ?? ""
        self = .maven(homeOverride: mavenHome.isEmpty ? javaHome : mavenHome)
    }
}

/// Maps an editor target and the language-neutral run model into adapter launch
/// arguments. It contains no process or UI code, so platform composition can
/// supply only the Java runtime and plugin launch capabilities.
struct DebugLaunchConfigurationResolver {
    private let javaTestLaunchResolver: (any JavaTestDebugLaunchResolving)?
    /// Path of the `java` executable Run uses for a runtime. Without it the
    /// Java Debug Server picks the JVM, which is the one JDT LS runs on.
    private let javaExecutablePath: (@MainActor (DebugJavaRuntime) -> String?)?
    /// The launch of a language a plugin's debug adapter serves. Returns nil
    /// when no adapter serves the language.
    private let pluginLaunch: (@MainActor (_ languageID: String, _ documentURL: URL, _ workspaceURL: URL) throws -> DebugLaunchConfiguration?)?

    init(
        javaTestLaunchResolver: (any JavaTestDebugLaunchResolving)? = nil,
        javaExecutablePath: (@MainActor (DebugJavaRuntime) -> String?)? = nil,
        pluginLaunch: (@MainActor (String, URL, URL) throws -> DebugLaunchConfiguration?)? = nil
    ) {
        self.pluginLaunch = pluginLaunch
        self.javaTestLaunchResolver = javaTestLaunchResolver
        self.javaExecutablePath = javaExecutablePath
    }

    /// `javaExec` for a launch, so the debugged JVM is the one Run starts.
    /// An unusable JDK fails the launch exactly as it fails Run.
    @MainActor
    private func javaExecutableArgument(
        for runtime: DebugJavaRuntime
    ) throws -> ToolingJSONValue? {
        guard let javaExecutablePath else { return nil }
        guard let path = javaExecutablePath(runtime) else {
            throw DebugLaunchConfigurationResolutionError.javaRuntimeUnavailable
        }
        return .string(path)
    }

    @MainActor
    func resolveJavaTest(
        target: JavaTestDebugLaunchTarget,
        resultPort: UInt16
    ) throws -> DebugLaunchConfiguration {
        guard let javaTestLaunchResolver else {
            throw DebugLaunchConfigurationResolutionError.javaLaunchTargetUnavailable
        }
        let configuration = try javaTestLaunchResolver.resolveJavaTestDebugLaunch(
            target: target,
            resultPort: resultPort
        )
        // Tests run through Maven, so a debugged test uses Maven's JDK.
        guard let javaExecutable = try javaExecutableArgument(for: .maven(homeOverride: nil)) else {
            return configuration
        }
        var arguments = configuration.arguments
        arguments["javaExec"] = javaExecutable
        return DebugLaunchConfiguration(
            name: configuration.name,
            request: configuration.request,
            arguments: arguments,
            steppingFilters: configuration.steppingFilters
        )
    }

    @MainActor
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
            return try javaConfiguration(
                documentURL: documentURL,
                workspaceURL: workspaceURL,
                configurations: configurations,
                selectedConfiguration: selectedConfiguration,
                target: javaTarget,
                options: options
            )
        default:
            if let configuration = try pluginLaunch?(provider.id, documentURL, workspaceURL) {
                return configuration
            }
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

    @MainActor
    private func javaConfiguration(
        documentURL: URL,
        workspaceURL: URL,
        configurations: [RunConfiguration],
        selectedConfiguration: RunConfiguration?,
        target: JavaDebugLaunchTarget,
        options: (RunConfiguration) -> RunOptions
    ) throws -> DebugLaunchConfiguration {
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
        if let javaExecutable = try javaExecutableArgument(
            for: DebugJavaRuntime(configuration: configuration, options: runOptions)
        ) {
            arguments["javaExec"] = javaExecutable
        }
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

}
