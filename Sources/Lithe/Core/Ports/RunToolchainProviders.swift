import Foundation

struct ResolvedRunToolchain: Sendable {
    let executableURL: URL
    let environment: [String: String]
}

struct DiscoveredRunToolchain: Sendable {
    let candidate: ProjectToolchainCandidate
    let executableURL: URL
}

@MainActor
protocol RunToolchainProvider: AnyObject {
    var identifiers: Set<String> { get }
    var toolchainType: String { get }
    /// Owning language pack, when this provider is language-specific.  A nil
    /// value is reserved for shared build tools such as Maven or Gradle.
    var languageProviderID: String? { get }
    func resolve(
        projectURL: URL,
        options: RunOptions,
        runtimeService: ProjectRuntimeService
    ) throws -> ResolvedRunToolchain

    func candidates(
        projectURL: URL,
        runtimeService: ProjectRuntimeService
    ) -> [ProjectToolchainCandidate]
}

extension RunToolchainProvider {
    var languageProviderID: String? { nil }

    func candidates(
        projectURL: URL,
        runtimeService: ProjectRuntimeService
    ) -> [ProjectToolchainCandidate] {
        identifiers.compactMap { identifier in
            guard (try? resolve(
                projectURL: projectURL,
                options: RunOptions(),
                runtimeService: runtimeService
            )) != nil else { return nil }
            return ProjectToolchainCandidate(
                id: identifier,
                type: toolchainType,
                version: "",
                vendor: ""
            )
        }
    }
}

@MainActor
final class RunToolchainRegistry {
    private var providersByIdentifier: [String: any RunToolchainProvider] = [:]

    init(providers: [any RunToolchainProvider] = []) {
        for provider in providers { register(provider) }
    }

    func register(_ provider: any RunToolchainProvider) {
        for identifier in provider.identifiers {
            providersByIdentifier[identifier] = provider
        }
    }

    func contains(identifier: String) -> Bool {
        providersByIdentifier[identifier] != nil
    }

    func resolve(
        identifier: String,
        projectURL: URL,
        options: RunOptions,
        runtimeService: ProjectRuntimeService
    ) throws -> ResolvedRunToolchain {
        guard let provider = providersByIdentifier[identifier] else {
            throw RunExecutableResolutionError(
                message: String(format: String(localized: "No resolver is registered for toolchain %@."), identifier)
            )
        }
        return try provider.resolve(
            projectURL: projectURL,
            options: options,
            runtimeService: runtimeService
        )
    }

    func candidates(
        projectURL: URL,
        runtimeService: ProjectRuntimeService,
        excludingTypes: Set<String> = []
    ) -> [ProjectToolchainCandidate] {
        discoveries(
            projectURL: projectURL,
            runtimeService: runtimeService,
            excludingTypes: excludingTypes
        ).map(\.candidate)
    }

    func discoveries(
        projectURL: URL,
        runtimeService: ProjectRuntimeService,
        excludingTypes: Set<String> = []
    ) -> [DiscoveredRunToolchain] {
        var visited = Set<ObjectIdentifier>()
        return providersByIdentifier.values.flatMap { provider -> [DiscoveredRunToolchain] in
            guard visited.insert(ObjectIdentifier(provider)).inserted else { return [] }
            guard !excludingTypes.contains(provider.toolchainType) else { return [] }
            return provider.identifiers.sorted().compactMap { identifier in
                guard let resolved = try? provider.resolve(
                    projectURL: projectURL,
                    options: RunOptions(),
                    runtimeService: runtimeService
                ) else { return nil }
                return DiscoveredRunToolchain(
                    candidate: ProjectToolchainCandidate(
                        id: identifier,
                        type: provider.toolchainType,
                        version: "",
                        vendor: ""
                    ),
                    executableURL: resolved.executableURL
                )
            }
        }
    }

    static func standard() -> RunToolchainRegistry {
        RunToolchainRegistry(providers: standardProviders())
    }

    static func standardProviders() -> [any RunToolchainProvider] {
        [
            JavaRunToolchainProvider(),
            MavenRunToolchainProvider(),
            GradleRunToolchainProvider(),
            PathRunToolchainProvider(
                identifiers: ["go", "project-go"], command: "go",
                languageProviderID: "go"),
            PathRunToolchainProvider(
                identifiers: ["python", "project-python"],
                command: "python3",
                fallbackCommand: "python",
                toolchainType: "python",
                languageProviderID: "python"),
            PathRunToolchainProvider(
                identifiers: ["node", "project-node"], command: "node",
                languageProviderID: "node"),
            PathRunToolchainProvider(
                identifiers: ["tsx", "project-tsx"],
                command: "tsx",
                fallbackCommand: "ts-node",
                toolchainType: "typescript",
                languageProviderID: "node"),
            PathRunToolchainProvider(
                identifiers: ["cargo", "project-cargo", "rust"],
                command: "cargo",
                toolchainType: "rust",
                languageProviderID: "rust")
        ]
    }
}

@MainActor
private final class GradleRunToolchainProvider: RunToolchainProvider {
    let identifiers: Set<String> = ["gradle", "project-gradle"]
    let toolchainType = "gradle"
    let languageProviderID: String? = "java"

    func resolve(
        projectURL: URL,
        options: RunOptions,
        runtimeService: ProjectRuntimeService
    ) throws -> ResolvedRunToolchain {
        guard let executable = runtimeService.gradleExecutable(at: projectURL) else {
            throw RunExecutableResolutionError(
                message: String(localized: "No Gradle wrapper or Gradle executable was found.")
            )
        }
        return ResolvedRunToolchain(
            executableURL: executable,
            environment: runtimeService.processEnvironment()
        )
    }
}

@MainActor
private final class JavaRunToolchainProvider: RunToolchainProvider {
    let identifiers: Set<String> = ["project-jdk"]
    let toolchainType = "java"
    let languageProviderID: String? = "java"

    func resolve(
        projectURL: URL,
        options: RunOptions,
        runtimeService: ProjectRuntimeService
    ) throws -> ResolvedRunToolchain {
        guard let executable = runtimeService.javaExecutableURL(overridePath: options.javaHomePath) else {
            throw RunExecutableResolutionError(
                message: String(localized: "No Java runtime was found. Set JAVA_HOME or install a JDK.")
            )
        }
        return ResolvedRunToolchain(
            executableURL: executable,
            environment: runtimeService.environment(
                for: .java,
                javaHomeOverride: options.javaHomePath
            )
        )
    }
}

@MainActor
private final class MavenRunToolchainProvider: RunToolchainProvider {
    let identifiers: Set<String> = ["project-maven"]
    let toolchainType = "maven"
    let languageProviderID: String? = "java"

    func resolve(
        projectURL: URL,
        options: RunOptions,
        runtimeService: ProjectRuntimeService
    ) throws -> ResolvedRunToolchain {
        guard let executable = runtimeService.mavenExecutable(
            at: projectURL,
            overridePath: options.mavenExecutablePath
        ) else {
            throw RunExecutableResolutionError(
                message: String(localized: "No Maven executable was found. Edit this service configuration.")
            )
        }
        return ResolvedRunToolchain(
            executableURL: executable,
            environment: runtimeService.environment(
                for: .maven,
                javaHomeOverride: options.mavenJavaHomePath.isEmpty
                    ? options.javaHomePath
                    : options.mavenJavaHomePath
            )
        )
    }
}

@MainActor
private final class PathRunToolchainProvider: RunToolchainProvider {
    let identifiers: Set<String>
    let toolchainType: String
    let languageProviderID: String?
    private let command: String
    private let fallbackCommand: String?

    init(
        identifiers: Set<String>,
        command: String,
        fallbackCommand: String? = nil,
        toolchainType: String? = nil,
        languageProviderID: String? = nil
    ) {
        self.identifiers = identifiers
        self.command = command
        self.fallbackCommand = fallbackCommand
        self.toolchainType = toolchainType ?? command
        self.languageProviderID = languageProviderID
    }

    func resolve(
        projectURL: URL,
        options: RunOptions,
        runtimeService: ProjectRuntimeService
    ) throws -> ResolvedRunToolchain {
        let executable = runtimeService.executableOnPath(command)
            ?? fallbackCommand.flatMap(runtimeService.executableOnPath)
        guard let executable else {
            throw RunExecutableResolutionError(
                message: runtimeService.missingToolMessage(command)
            )
        }
        return ResolvedRunToolchain(
            executableURL: executable,
            environment: runtimeService.processEnvironment()
        )
    }
}
