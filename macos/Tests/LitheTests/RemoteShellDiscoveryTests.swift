import Foundation
import Testing
@testable import Lithe

@Suite("Remote shell discovery")
struct RemoteShellDiscoveryTests {
    @Test
    func usesOnlyHostPathsAndExecutablePermissionsInStableOrder() throws {
        let host = ShellHost()
        let shells = try MacRemoteShellDiscovery.availableShells(session: "host-one", host: host, isCancelled: { false })
        #expect(shells == ["/host/bin/fish", "/host/bin/bash", "/host/bin/sh"])
        #expect(host.directories == ["/host/bin"])
        #expect(host.probedExecutables == ["/host/bin/sh"])
        #expect(host.sessions.allSatisfy { $0 == "host-one" })
    }

    @Test
    func discoveryFailureDoesNotReturnAPartialHostSnapshot() {
        let host = ShellHost(failsDirectory: true)
        #expect(throws: (any Error).self) {
            try MacRemoteShellDiscovery.availableShells(session: "host-one", host: host, isCancelled: { false })
        }
    }

    @Test
    func cancellationStopsBeforeAnyHostRequest() {
        let host = ShellHost()
        #expect(throws: CancellationError.self) {
            try MacRemoteShellDiscovery.availableShells(session: "host-one", host: host, isCancelled: { true })
        }
        #expect(host.sessions.isEmpty)
    }

    @Test
    func emptyHostEnvironmentDoesNotSearchMacSystemDirectories() throws {
        let host = ShellHost(emptyEnvironment: true)
        #expect(try MacRemoteShellDiscovery.availableShells(session: "host-one", host: host, isCancelled: { false }).isEmpty)
        #expect(host.directories.isEmpty)
    }
}

/// Used synchronously on the test's thread; the async worker's host is tested
/// through its protocol elsewhere. No real host or installed shell is required.
private final class ShellHost: RemoteShellProbing, @unchecked Sendable {
    var directories: [String] = []
    var probedExecutables: [String] = []
    var sessions: [String] = []
    let failsDirectory: Bool
    let emptyEnvironment: Bool
    init(failsDirectory: Bool = false, emptyEnvironment: Bool = false) {
        self.failsDirectory = failsDirectory
        self.emptyEnvironment = emptyEnvironment
    }
    func shellEnvironment(session: String) throws -> [String: String] {
        sessions.append(session)
        return emptyEnvironment ? [:] : ["SHELL": "/host/bin/fish", "PATH": "/host/bin:/host/bin:relative"]
    }
    func registeredShells(session: String) throws -> String {
        sessions.append(session)
        return emptyEnvironment ? "" : "# host shells\n/host/bin/fish\n/host/bin/bash\n/host/bin/nu\nrelative"
    }
    func runtimeDirectory(_ path: String, session: String) throws -> [RemoteDirectoryEntry] {
        sessions.append(session)
        directories.append(path)
        if failsDirectory { throw RemoteProbeFailure(code: "connection_closed", message: "fixture disconnected") }
        return [
            .init(name: "fish", metadata: .init(kind: "file", mode: 0o755)),
            .init(name: "bash", metadata: .init(kind: "symlink", symlinkTargetKind: "file", symlinkTargetMode: 0o755)),
            .init(name: "nu", metadata: .init(kind: "file", mode: 0o644)),
            .init(name: "sh", metadata: .init(kind: "symlink", symlinkTargetKind: "file")),
            .init(name: "dash", metadata: .init(kind: "symlink", symlinkTargetKind: "file", symlinkTargetMode: 0o644)),
            .init(name: "zsh", metadata: .init(kind: "directory", mode: 0o755)),
        ]
    }
    func runtimeExecutable(_ path: String, session: String) throws -> Bool {
        sessions.append(session)
        probedExecutables.append(path)
        return path == "/host/bin/sh"
    }
}
