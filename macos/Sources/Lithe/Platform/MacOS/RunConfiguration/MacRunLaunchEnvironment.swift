import Foundation

extension RustCoreBridge: RunLaunchEnvironmentResolving {
    private struct LaunchEnvironmentPayload: Encodable {
        let toolchain: String?
        let javaHome: String?
        let mavenJavaHome: String?
        let inherited: [String: String]
        let overrides: [String: String]
    }

    private struct LaunchEnvironmentResult: Decodable {
        let environment: [String: String]
    }

    func resolveLaunchEnvironment(
        toolchain: String?, selectedHome: String?,
        inherited: [String: String], overrides: [String: String]
    ) throws -> [String: String] {
        let result: LaunchEnvironmentResult = try executeResult(
            command: "execution.resolveEnvironment",
            payload: LaunchEnvironmentPayload(
                toolchain: toolchain, javaHome: selectedHome, mavenJavaHome: selectedHome,
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
