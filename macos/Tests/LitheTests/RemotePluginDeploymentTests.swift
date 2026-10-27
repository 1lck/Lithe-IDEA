import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning
import Testing
@testable import Lithe

@Suite("Remote plugin deployment")
struct RemotePluginDeploymentTests {
    @Test
    func deploysApprovedBytesReadOnlyAndReleasesOriginalHost() async throws {
        let fixture = try DeploymentFixture()
        defer { fixture.remove() }
        let host = DeploymentHostFixture()
        let deployer = fixture.deployer(host)
        let before = try PluginPackageSignature.contentDigest(packageAt: fixture.package.packageURL)
        let result = try await deployer.deploy(pluginID: fixture.id, packageURL: fixture.package.packageURL, session: "original")
        #expect(result.packageURL.path.hasPrefix("/host/.lithe-server/plugin-runs/"))
        #expect(host.uploads.count == 2)
        #expect(host.uploads.contains(where: { $0.mode == 0o500 && $0.target.hasSuffix("/server/run") }))
        #expect(host.uploads.contains(where: { $0.mode == 0o400 && $0.target.hasSuffix("/plugin.json") }))
        #expect(host.removals.isEmpty)
        await result.release()
        #expect(host.removals.count == 1)
        #expect(host.removals.first?.session == "original")
        #expect(host.removals.first?.directoryID == host.allocations.first)
        #expect(try PluginPackageSignature.contentDigest(packageAt: fixture.package.packageURL) == before)
    }

    @Test
    func transferFailureAndCancellationRemoveOwnedSnapshot() async throws {
        let fixture = try DeploymentFixture()
        defer { fixture.remove() }
        let host = DeploymentHostFixture()
        host.failsUpload = true
        await #expect(throws: CocoaError.self) {
            _ = try await fixture.deployer(host).deploy(pluginID: fixture.id, packageURL: fixture.package.packageURL, session: "failed")
        }
        #expect(host.removals.map(\.session) == ["failed"])
        let blocked = DeploymentHostFixture()
        blocked.blocksUpload = true
        let deployer = fixture.deployer(blocked)
        let completed = TestGate()
        let task = Task {
            defer { completed.open() }
            return try await deployer.deploy(pluginID: fixture.id, packageURL: fixture.package.packageURL, session: "cancelled")
        }
        defer { task.cancel(); blocked.release.open() }
        try #require(await blocked.started.waitUntilOpen(timeout: .seconds(5)))
        task.cancel()
        try #require(await completed.waitUntilOpen(timeout: .seconds(5)))
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(blocked.removals.map(\.session) == ["cancelled"])
        #expect(!blocked.cleanupWasCancelled)
    }

    @Test
    func changedApprovedPackageAndUnsupportedTargetNeverUpload() async throws {
        let fixture = try DeploymentFixture()
        defer { fixture.remove() }
        let host = DeploymentHostFixture()
        host.facts = .init(os: "linux", arch: "aarch64", homeDirectory: "/host", features: ["upload", "runDirectories"])
        let deployer = fixture.deployer(host)
        await #expect(throws: DeclarativePluginRejection.self) {
            _ = try await deployer.deploy(pluginID: fixture.id, packageURL: fixture.package.packageURL, session: "linux")
        }
        #expect(host.uploads.isEmpty)
        host.facts = DeploymentHostFixture.currentHost
        try Data("changed".utf8).write(to: fixture.package.packageURL.appendingPathComponent("server/run"))
        await #expect(throws: PluginPackageStoreError.self) {
            _ = try await deployer.deploy(pluginID: fixture.id, packageURL: fixture.package.packageURL, session: "changed")
        }
        #expect(host.uploads.isEmpty)
        #expect(host.removals.isEmpty)
        #expect(host.allocations.isEmpty)
    }

    @Test
    func lostAllocationResponseReleasesTheIdentityKnownBeforeTheRequest() async throws {
        let fixture = try DeploymentFixture()
        defer { fixture.remove() }
        let host = DeploymentHostFixture()
        host.losesAllocationResponse = true
        await #expect(throws: CocoaError.self) {
            _ = try await fixture.deployer(host).deploy(pluginID: fixture.id,
                packageURL: fixture.package.packageURL, session: "lost-response")
        }
        #expect(host.allocations.count == 1)
        #expect(host.removals.count == 1)
        #expect(host.removals.first?.directoryID == host.allocations.first)
        #expect(host.removals.first?.session == "lost-response")
        #expect(host.uploads.isEmpty)
    }

    @Test
    func olderHostWithoutSessionOwnedDirectoriesNeverAllocatesOrUploads() async throws {
        let fixture = try DeploymentFixture()
        defer { fixture.remove() }
        let host = DeploymentHostFixture()
        host.facts = .init(os: "macos", arch: DeploymentHostFixture.currentHost.arch,
            homeDirectory: "/host", features: ["upload"])
        await #expect(throws: DeclarativePluginRejection.self) {
            _ = try await fixture.deployer(host).deploy(pluginID: fixture.id,
                packageURL: fixture.package.packageURL, session: "older-host")
        }
        #expect(host.uploads.isEmpty)
        #expect(host.removals.isEmpty)
    }

    @Test
    func hostArchitectureUsesHandshakeFacts() {
        #expect(RemotePluginHost(os: "linux", arch: "aarch64", homeDirectory: nil, features: []).platform == "linux-arm64")
        #expect(RemotePluginHost(os: "linux", arch: "aarch64", homeDirectory: nil, features: []).templateArchitecture == "arm64")
        #expect(RemotePluginHost(os: "macos", arch: "x86_64", homeDirectory: nil, features: []).platform == "darwin-x64")
        #expect(RemotePluginHost(os: "linux", arch: "unknown", homeDirectory: nil, features: []).platform == nil)
    }
}

private struct DeploymentFixture {
    let root: URL
    let package: InstalledPluginPackage
    var id: String { package.descriptor.id.rawValue }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-deploy-test-" + UUID().uuidString)
        do {
            let source = try DeclarativePluginTestSupport.writePackage(at: root.appendingPathComponent("source"),
                manifest: DeclarativePluginTestSupport.manifestObject(version: .init(major: 1, minor: 0, patch: 0),
                    signatureRequirement: .unsigned, packagedLauncher: "server/run"))
            let digest = try PluginPackageSignature.contentDigest(packageAt: source)
            package = try MacPluginPackageStore(rootURL: root.appendingPathComponent("installed"),
                validator: DeclarativePluginTestSupport.operations).installPackage(from: source, origin: .community,
                    disk: .init(fileName: "fixture.zip", archiveSHA256: nil, contentDigest: digest, approvedPrograms: []))
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func deployer(_ host: DeploymentHostFixture) -> MacRemotePluginPackageDeployer {
        let root = root
        return MacRemotePluginPackageDeployer(installed: [package], makeStore: { architecture in
            MacPluginPackageStore(rootURL: root.appendingPathComponent("unused"),
                validator: DeclarativePluginTestSupport.operations, architecture: architecture)
        }, evaluator: RustPluginMarketplaceOperations(core: RustCoreBridge()), transport: NoDeploymentNetwork(),
            host: host, temporaryDirectory: root)
    }
}

private struct NoDeploymentNetwork: MacPluginMarketplaceTransport {
    func data(from url: URL, maximumBytes: Int64) async throws -> Data {
        Issue.record("Disk approval must not acquire repository provenance")
        throw CocoaError(.featureUnsupported)
    }
    func download(from url: URL, maximumBytes: Int64) async throws -> URL {
        Issue.record("This test must not download packages")
        throw CocoaError(.featureUnsupported)
    }
}

private final class DeploymentHostFixture: RemotePluginFileAccess, @unchecked Sendable {
    struct Upload { let target: String; let mode: UInt32 }
    struct Removal { let session: String; let directoryID: String }
    static let currentHost = RemotePluginHost(os: "macos",
        arch: MacPluginLanguageServerLaunchResolver.hostArchitecture == "arm64" ? "aarch64" : "x86_64",
        homeDirectory: "/host", features: ["upload", "runDirectories"])
    private let lock = NSLock()
    // Scripted outcomes change only between awaited calls.
    var facts = currentHost
    var failsUpload = false
    var blocksUpload = false
    var losesAllocationResponse = false
    private var sent: [Upload] = []
    private var removed: [Removal] = []
    private var cancelledCleanup = false
    private var allocated: [String] = []
    let started = TestGate()
    let release = TestGate()
    var uploads: [Upload] { lock.withLock { sent } }
    var removals: [Removal] { lock.withLock { removed } }
    var cleanupWasCancelled: Bool { lock.withLock { cancelledCleanup } }
    var allocations: [String] { lock.withLock { allocated } }
    func pluginHost(session: String) async throws -> RemotePluginHost { facts }
    func pluginRequest(_ method: String, params: ToolingJSONValue, session: String) async throws -> ToolingJSONValue {
        if method == "fs.stat" { return .object(["kind": .string("directory"), "mode": .integer(0o700)]) }
        if method == "fs.createRunDirectory", case .object(let values) = params,
           case .string(let id) = values["directoryId"] {
            lock.withLock { allocated.append(id) }
            if losesAllocationResponse { throw CocoaError(.fileReadUnknown) }
            return .object(["path": .string("/host/.lithe-server/plugin-runs/" + id)])
        }
        if method == "fs.releaseRunDirectory", case .object(let values) = params,
           case .string(let id) = values["directoryId"] {
            lock.withLock { removed.append(.init(session: session, directoryID: id)); cancelledCleanup = Task.isCancelled }
        }
        return .null
    }
    func uploadPluginFile(_ source: URL, to path: String, sha256: String, mode: UInt32, session: String) async throws {
        #expect(try MacPluginPackageDownloader.sha256(of: source) == sha256)
        lock.withLock { sent.append(.init(target: path, mode: mode)) }
        if failsUpload { throw CocoaError(.fileWriteUnknown) }
        if blocksUpload {
            started.open()
            _ = await release.waitUntilOpen(timeout: .seconds(5))
            try Task.checkCancellation()
        }
    }
}
