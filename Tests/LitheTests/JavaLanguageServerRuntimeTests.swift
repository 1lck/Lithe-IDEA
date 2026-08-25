import Foundation
import Testing
@testable import Lithe

@Suite("Java language server runtime")
struct JavaLanguageServerRuntimeTests {
    @Test
    func parsesModernAndLegacyJavaVersions() {
        #expect(javaRuntime("/jdk-17", "17.0.18").majorVersion == 17)
        #expect(javaRuntime("/jdk-21", "21-ea").majorVersion == 21)
        #expect(javaRuntime("/jdk-8", "1.8.0_442").majorVersion == 8)
        #expect(javaRuntime("/jdk-unknown", "unknown").majorVersion == nil)
    }

    @Test
    func jdtlsCompatibilityRequiresJava17OrNewer() {
        #expect(!javaRuntime("/jdk-11", "11.0.26").supportsJDTLS)
        #expect(javaRuntime("/jdk-17", "17.0.18").supportsJDTLS)
        #expect(javaRuntime("/jdk-21", "21.0.10").supportsJDTLS)
    }

    @Test
    @MainActor
    func bundledJdtlsRuntimeIgnoresProjectRunJDK() async {
        let projectRuntime = javaRuntime("/project/jdk-11", "11.0.26")
        let jdtlsRuntime = javaRuntime("/language-server/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [projectRuntime, jdtlsRuntime],
                bundledHomePath: jdtlsRuntime.homePath
            ),
            store: JavaLanguageServerTestStore()
        )

        #expect(
            service.javaHomeURL(overridePath: projectRuntime.homePath)?.path
                == projectRuntime.homePath
        )
        #expect(service.javaLanguageServerExecutableURL() == nil)
        await service.prepareJavaLanguageServerRuntime()
        #expect(
            service.javaLanguageServerExecutableURL()?.path
                == "/language-server/jdk-21/bin/java"
        )
    }

    @Test
    @MainActor
    func bundledJdtlsRuntimeRejectsNonJdk21() async {
        let unsupportedRuntime = javaRuntime("/jdk-17", "17.0.18")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [unsupportedRuntime],
                bundledHomePath: unsupportedRuntime.homePath
            ),
            store: JavaLanguageServerTestStore()
        )

        let result = await service.prepareJavaLanguageServerRuntime()

        #expect(service.javaLanguageServerExecutableURL() == nil)
        guard case .failed(let message) = result else {
            Issue.record("Expected the bundled JDK version check to fail")
            return
        }
        #expect(message.contains("JDK 21"))
    }

    @Test
    @MainActor
    func missingBundledJdtlsRuntimeDoesNotUseDiscoveredJDK() async {
        let discoveredRuntime = javaRuntime("/system/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [discoveredRuntime],
                bundledHomePath: nil
            ),
            store: JavaLanguageServerTestStore()
        )

        let result = await service.prepareJavaLanguageServerRuntime()

        #expect(service.javaLanguageServerExecutableURL() == nil)
        guard case .failed(let message) = result else {
            Issue.record("Expected a missing bundled JDK failure")
            return
        }
        #expect(message.contains("bundled Temurin JDK 21"))
    }

    @Test
    @MainActor
    func preparationOwnerCancelsAndReleasesItsTask() {
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: URL(fileURLWithPath: "/workspace", isDirectory: true),
            operationID: UUID()
        )
        let task = Task { @MainActor () -> Void in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
        }
        owner.task = task

        owner.cancel()

        #expect(task.isCancelled)
        #expect(owner.task == nil)
    }

    @Test
    @MainActor
    func workspaceStateKeepsPreparationOperationIdentity() {
        let workspaceURL = URL(fileURLWithPath: "/workspace", isDirectory: true)
        let operationID = UUID()
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: workspaceURL,
            operationID: operationID
        )
        let state = JavaLanguageServerWorkspaceState.preparing(owner: owner)

        #expect(state.operationID == operationID)
        #expect(state.belongs(to: workspaceURL))
        #expect(!state.belongs(to: URL(fileURLWithPath: "/other", isDirectory: true)))
    }

    private func javaRuntime(_ homePath: String, _ version: String) -> JavaRuntimeCandidate {
        JavaRuntimeCandidate(homePath: homePath, version: version, vendor: "Test JDK")
    }
}

private struct JavaLanguageServerTestRuntimeLocator: RuntimeLocator {
    let runtimes: [JavaRuntimeCandidate]
    let bundledHomePath: String?

    init(
        runtimes: [JavaRuntimeCandidate],
        bundledHomePath: String? = nil
    ) {
        self.runtimes = runtimes
        self.bundledHomePath = bundledHomePath
    }

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        return RuntimeDiscoveryResult(javaRuntimes: runtimes, mavenRuntimes: [])
    }

    func validJavaHome(path: String) -> URL? {
        runtimes.contains(where: { $0.homePath == path })
            ? URL(fileURLWithPath: path, isDirectory: true)
            : nil
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        runtimes.first(where: { $0.homePath == homeURL.standardizedFileURL.path })
    }

    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
    func systemJDBExecutable() -> URL? { nil }
    func bundledJdkHome() -> URL? {
        bundledHomePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

private struct JavaLanguageServerTestStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
