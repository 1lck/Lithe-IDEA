import Foundation

extension RustCoreBridge: RunLaunchEnvironmentResolving {
    private struct SearchPathPayload: Encodable {
        let existing: [String]
        let candidates: [RunSearchPathCandidate]
        let caseInsensitive = false
    }

    func resolveSearchPath(existing: [String], candidates: [RunSearchPathCandidate]) throws -> [String] {
        try executeResult(command: "execution.resolveSearchPath", payload: SearchPathPayload(
            existing: existing, candidates: candidates
        )).get()
    }

    private struct LaunchEnvironmentPayload: Encodable {
        let toolchain: String?
        let inherited: [String: String]
        let overrides: [String: String]
    }

    private struct LaunchEnvironmentResult: Decodable {
        let environment: [String: String]
    }

    func resolveLaunchEnvironment(
        toolchain: String?,
        inherited: [String: String], overrides: [String: String]
    ) throws -> [String: String] {
        let result: LaunchEnvironmentResult = try executeResult(
            command: "execution.resolveEnvironment",
            payload: LaunchEnvironmentPayload(
                toolchain: toolchain,
                inherited: inherited, overrides: overrides
            )
        ).get()
        return result.environment
    }
}

@MainActor
extension RunExecutableResolver {
    convenience init(
        runtimeService: ProjectRuntimeService,
        toolchainRegistry: RunToolchainRegistry? = nil,
        metadataResolver: (any RunToolchainMetadataResolving)? = nil
    ) {
        self.init(runtimeService: runtimeService, toolchainRegistry: toolchainRegistry,
                  metadataResolver: metadataResolver, environmentResolver: RustCoreBridge())
    }
}
