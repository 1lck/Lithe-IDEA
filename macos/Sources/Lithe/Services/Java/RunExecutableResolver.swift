import Foundation

@MainActor
final class RunExecutableResolver: RunExecutableResolving {
    private let runtimeService: ProjectRuntimeService
    private let toolchainRegistry: RunToolchainRegistry
    private let metadataResolver: (any RunToolchainMetadataResolving)?
    private var metadataByProject: [String: [String: RunToolchainMetadata]] = [:]

    init(
        runtimeService: ProjectRuntimeService,
        toolchainRegistry: RunToolchainRegistry? = nil,
        metadataResolver: (any RunToolchainMetadataResolving)? = nil
    ) {
        self.runtimeService = runtimeService
        self.toolchainRegistry = toolchainRegistry ?? .standard()
        self.metadataResolver = metadataResolver
    }

    func resolve(
        _ plan: SharedLaunchPlan,
        projectURL: URL,
        options: RunOptions
    ) throws -> ResolvedRunExecutable {
        let planEnvironment = plan.environment.merging(options.environment) { _, userValue in userValue }

        let resolved: ResolvedRunExecutable
        switch plan.executable {
        case .toolchain(let id):
            let toolchainProjectURL = id == "project-maven" && plan.workingDirectory != "."
                ? projectURL.appending(path: plan.workingDirectory, directoryHint: .isDirectory)
                : projectURL
            let toolchain = try toolchainRegistry.resolve(
                identifier: id,
                projectURL: toolchainProjectURL.standardizedFileURL,
                options: options,
                runtimeService: runtimeService
            )
            resolved = ResolvedRunExecutable(
                executableURL: toolchain.executableURL,
                environment: toolchain.environment.merging(planEnvironment) { _, override in override }
            )

        case .command(let command):
            guard let executable = runtimeService.executableOnPath(command) else {
                throw RunExecutableResolutionError(
                    message: runtimeService.missingToolMessage(command)
                )
            }
            resolved = ResolvedRunExecutable(
                executableURL: executable,
                environment: runtimeService.processEnvironment(overrides: planEnvironment)
            )
        }

        return ResolvedRunExecutable(
            executableURL: resolved.executableURL,
            environment: RunLaunchEnvironment.augmenting(
                resolved.environment,
                executableURL: resolved.executableURL,
                nodeCandidates: runtimeService.executableCandidates("node"),
                projectURL: projectURL
            )
        )
    }

    func refreshCandidates(projectURL: URL) async {
        guard let metadataResolver else { return }
        let discoveries = toolchainRegistry.discoveries(
            projectURL: projectURL,
            runtimeService: runtimeService,
            excludingTypes: ["java", "maven"]
        )
        let metadata = await Task.detached(priority: .utility) {
            var probeCache: [String: RunToolchainMetadata] = [:]
            var result: [String: RunToolchainMetadata] = [:]
            for discovery in discoveries {
                let key = discovery.candidate.type + "\u{0}" + discovery.executableURL.standardizedFileURL.path
                let value: RunToolchainMetadata
                if let cached = probeCache[key] {
                    value = cached
                } else {
                    value = metadataResolver.metadata(
                        for: discovery.executableURL,
                        toolchainType: discovery.candidate.type
                    )
                    probeCache[key] = value
                }
                result[discovery.candidate.id] = value
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        metadataByProject[projectURL.standardizedFileURL.path] = metadata
    }

    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] {
        let metadata = metadataByProject[projectURL.standardizedFileURL.path] ?? [:]
        return toolchainRegistry
            .candidates(
                projectURL: projectURL,
                runtimeService: runtimeService,
                excludingTypes: ["java", "maven"]
            )
            .map { candidate in
                guard let value = metadata[candidate.id] else { return candidate }
                return ProjectToolchainCandidate(
                    id: candidate.id,
                    type: candidate.type,
                    version: value.version,
                    vendor: value.vendor
                )
            }
    }
}
