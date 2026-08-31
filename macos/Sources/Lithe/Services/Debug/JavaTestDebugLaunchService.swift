import Foundation
import LitheCoreContracts

/// Prepared Java test launch plus the short-lived result channel it owns.
@MainActor
struct PreparedJavaTestDebugLaunch {
    let target: JavaTestDebugLaunchTarget
    let configuration: DebugLaunchConfiguration
    let resultServer: any JavaTestResultServing

    func stop() {
        resultServer.stop()
    }
}

/// Coordinates Java test target resolution with the native result listener and
/// shared Rust launch configuration without owning UI or Debug Adapter state.
@MainActor
final class JavaTestDebugLaunchService {
    private let configurationResolver: DebugLaunchConfigurationResolver
    private let resultServerFactory: @MainActor () -> any JavaTestResultServing

    init(
        configurationResolver: DebugLaunchConfigurationResolver,
        resultServerFactory: @escaping @MainActor () -> any JavaTestResultServing
    ) {
        self.configurationResolver = configurationResolver
        self.resultServerFactory = resultServerFactory
    }

    func prepare(
        fileURL: URL,
        testIdentifier: String?,
        rootURL: URL,
        targetResolver: any JavaTestDebugLaunchTargetResolving
    ) async throws -> PreparedJavaTestDebugLaunch {
        let target = try await targetResolver.resolveJavaTestDebugLaunchTarget(
            fileURL: fileURL,
            testIdentifier: testIdentifier,
            rootURL: rootURL
        )
        try Task.checkCancellation()

        let resultServer = resultServerFactory()
        do {
            let resultPort = try await resultServer.start()
            try Task.checkCancellation()
            let configuration = try configurationResolver.resolveJavaTest(
                target: target,
                resultPort: resultPort
            )
            return PreparedJavaTestDebugLaunch(
                target: target,
                configuration: configuration,
                resultServer: resultServer
            )
        } catch {
            resultServer.stop()
            throw error
        }
    }
}
