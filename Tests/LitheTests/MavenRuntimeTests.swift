import Foundation
import Testing
@testable import Lithe

@Suite("Maven and runtime integration")
struct MavenRuntimeTests {
    @Test
    func mavenScanPayloadDecodesRustCamelCaseIdentifiers() throws {
        let json = #"""
        {
            "groupId": "com.example",
            "artifactId": "root",
            "version": "1.0",
            "packaging": "pom",
            "modules": [{
                "relativePath": "module-a",
                "groupId": "com.example",
                "artifactId": "child",
                "version": "1.0",
                "packaging": "jar",
                "modules": []
            }],
            "profiles": [{"id": "dev", "isActiveByDefault": true}],
            "hasWrapper": true
        }
        """#
        let payload = try JSONDecoder().decode(
            RustCoreBridge.MavenScanPayload.self,
            from: Data(json.utf8)
        )

        let project = payload.makeProject(rootURL: URL(fileURLWithPath: "/tmp/maven"))
        #expect(project.groupID == "com.example")
        #expect(project.artifactID == "root")
        #expect(project.modules.count == 1)
        #expect(project.modules[0].groupID == "com.example")
        #expect(project.modules[0].artifactID == "child")
        #expect(project.profiles == [MavenProfile(id: "dev", isActiveByDefault: true)])
        #expect(project.hasWrapper)
    }

    @Test
    @MainActor
    func canceledRuntimeDiscoveryClearsDiscoveringState() async throws {
        let locator = BlockingRuntimeLocator()
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        let task = Task { @MainActor in
            await service.refreshAvailableRuntimes()
        }

        for _ in 0..<100 where !locator.hasStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(locator.hasStarted)
        #expect(service.isDiscovering)

        task.cancel()
        locator.release()
        await task.value

        #expect(!service.isDiscovering)
    }
}

private final class BlockingRuntimeLocator: RuntimeLocator, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var startedValue = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedValue
    }

    func release() {
        releaseSemaphore.signal()
    }

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        lock.lock()
        startedValue = true
        lock.unlock()
        releaseSemaphore.wait()
        return RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }

    func validJavaHome(path: String) -> URL? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func systemJDBExecutable() -> URL? { nil }
    func javaLanguageServerExecutable() -> URL? { nil }
}

private struct EmptyKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
