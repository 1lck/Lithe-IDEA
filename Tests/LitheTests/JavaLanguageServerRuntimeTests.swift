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
    func automaticJdtlsRuntimeIgnoresProjectRunJDK() async {
        let projectRuntime = javaRuntime("/project/jdk-11", "11.0.26")
        let jdtlsRuntime = javaRuntime("/language-server/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [projectRuntime, jdtlsRuntime]
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
    func manualJdtlsRuntimeRejectsOldJavaAndAcceptsJava17() async {
        let oldRuntime = javaRuntime("/jdk-11", "11.0.26")
        let supportedRuntime = javaRuntime("/jdk-17", "17.0.18")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [supportedRuntime, oldRuntime]
            ),
            store: JavaLanguageServerTestStore()
        )

        #expect(await service.inspectJavaLanguageServerRuntime(atPath: oldRuntime.homePath) == oldRuntime)
        await service.prepareJavaLanguageServerRuntime(overridePath: oldRuntime.homePath)
        #expect(service.javaLanguageServerExecutableURL(overridePath: oldRuntime.homePath) == nil)
        await service.prepareJavaLanguageServerRuntime(overridePath: supportedRuntime.homePath)
        #expect(
            service.javaLanguageServerExecutableURL(overridePath: supportedRuntime.homePath)?.path
                == "/jdk-17/bin/java"
        )
    }

    @Test
    @MainActor
    func automaticJdtlsRuntimeDiscoveryRunsOffTheMainThread() async {
        let recorder = JavaLanguageServerDiscoveryThreadRecorder()
        let runtime = javaRuntime("/jdk-21", "21.0.10")
        let service = ProjectRuntimeService(
            runtimeLocator: JavaLanguageServerTestRuntimeLocator(
                runtimes: [runtime],
                threadRecorder: recorder
            ),
            store: JavaLanguageServerTestStore()
        )

        await service.prepareJavaLanguageServerRuntime()

        #expect(recorder.discoveryWasOnMainThread == false)
        #expect(service.javaLanguageServerExecutableURL()?.path == "/jdk-21/bin/java")
    }

    private func javaRuntime(_ homePath: String, _ version: String) -> JavaRuntimeCandidate {
        JavaRuntimeCandidate(homePath: homePath, version: version, vendor: "Test JDK")
    }
}

private struct JavaLanguageServerTestRuntimeLocator: RuntimeLocator {
    let runtimes: [JavaRuntimeCandidate]
    var threadRecorder: JavaLanguageServerDiscoveryThreadRecorder?

    init(
        runtimes: [JavaRuntimeCandidate],
        threadRecorder: JavaLanguageServerDiscoveryThreadRecorder? = nil
    ) {
        self.runtimes = runtimes
        self.threadRecorder = threadRecorder
    }

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        threadRecorder?.recordDiscoveryThread()
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
    func javaLanguageServerExecutable() -> URL? { nil }
}

private final class JavaLanguageServerDiscoveryThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var discoveryWasOnMainThreadValue: Bool?

    var discoveryWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return discoveryWasOnMainThreadValue
    }

    func recordDiscoveryThread() {
        lock.lock()
        discoveryWasOnMainThreadValue = Thread.isMainThread
        lock.unlock()
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
