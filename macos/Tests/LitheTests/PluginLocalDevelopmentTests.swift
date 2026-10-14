import CryptoKit
import Foundation
@testable import Lithe
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning
import Testing

/// Exercises the production signature verifier with an injected publisher key
/// and declarative fixture packages, covering the local development install
/// path that lets plugin authors test without the release key.
struct PluginLocalDevelopmentTests {
    @Test
    func publisherPackageSignedWithATrustedKeyIDIsAccepted() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        try fixture.signPackage(keyID: "test-publisher-v1")

        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: false,
            hostBundleURL: fixture.hostBundleURL
        )

        try verifier.verify(packageAt: fixture.packageURL, manifest: fixture.manifest, origin: .marketplace)
    }

    @Test
    func publisherPackageSignedWithAnUnknownKeyIDIsRejected() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        try fixture.signPackage(keyID: "test-publisher-retired")

        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.invalidPackageSignature(
            PluginPackageSignature.Error.untrustedKey("test-publisher-retired").localizedDescription
        )) {
            try verifier.verify(packageAt: fixture.packageURL, manifest: fixture.manifest, origin: .marketplace)
        }
    }

    @Test
    func unsignedPackageIsAcceptedOnlyAsALocalDevelopmentPackage() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let developmentVerifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: [:],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        try developmentVerifier.verify(
            packageAt: fixture.packageURL,
            manifest: fixture.manifest,
            origin: .localDevelopment
        )
        #expect(throws: PluginPackageStoreError.missingPackageSignature) {
            try developmentVerifier.verify(
                packageAt: fixture.packageURL,
                manifest: fixture.manifest,
                origin: .marketplace
            )
        }
    }

    @Test
    func releaseBuildsRejectLocalDevelopmentPackages() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let releaseVerifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: [:],
            allowsLocalDevelopmentPackages: false,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.developmentPackageNotAllowed(fixture.manifest.id)) {
            try releaseVerifier.verify(
                packageAt: fixture.packageURL,
                manifest: fixture.manifest,
                origin: .localDevelopment
            )
        }
    }

    @Test
    func developmentOriginDoesNotBypassAPresentPublisherSignature() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        try fixture.signPackage(keyID: "test-publisher-v1")
        try Data("changed".utf8).write(
            to: fixture.packageURL.appendingPathComponent("notes.txt"),
            options: .atomic
        )
        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.invalidPackageSignature(
            PluginPackageSignature.Error.fileListMismatch.localizedDescription
        )) {
            try verifier.verify(
                packageAt: fixture.packageURL,
                manifest: fixture.manifest,
                origin: .localDevelopment
            )
        }
    }

    @Test
    func storeKeepsTheDevelopmentOriginAcrossRescans() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let installedRoot = fixture.root.appendingPathComponent("installed", isDirectory: true)
        let developmentStore = MacPluginPackageStore(
            rootURL: installedRoot,
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: true,
                hostBundleURL: fixture.hostBundleURL
            )
        )

        let installed = try developmentStore.installPackage(
            from: fixture.packageURL,
            origin: .localDevelopment
        )
        #expect(installed.installation.origin == .localDevelopment)
        let developmentScan = try developmentStore.scanInstalledPlugins()
        #expect(developmentScan.packages.map(\.installation.origin) == [.localDevelopment])
        #expect(developmentScan.issues.isEmpty)

        let releaseScan = try MacPluginPackageStore(
            rootURL: installedRoot,
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: false,
                hostBundleURL: fixture.hostBundleURL
            )
        ).scanInstalledPlugins()
        #expect(releaseScan.packages.isEmpty)
        #expect(releaseScan.issues == [PluginPackageScanIssue(
            pluginID: fixture.manifest.id,
            message: PluginPackageStoreError.developmentPackageNotAllowed(fixture.manifest.id)
                .localizedDescription
        )])
    }

    @Test
    @MainActor
    func managerInstallsAnUnsignedDiskPackageAsADevelopmentPackage() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let configuration = MacModuleConfigurationStore(store: PluginLocalDevelopmentKeyValueStore())
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(
                rootURL: fixture.root.appendingPathComponent("installed", isDirectory: true),
                validator: DeclarativePluginTestSupport.operations,
                verifier: MacOfficialPluginSignatureVerifier(
                    trustedPublisherKeys: [:],
                    allowsLocalDevelopmentPackages: true,
                    hostBundleURL: fixture.hostBundleURL
                )
            ),
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            settings: InMemoryPluginSettings(),
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                registeredPlugins: [],
                issues: []
            ),
            allowsLocalDevelopmentPackages: true
        )

        try manager.installPackage(at: fixture.packageURL)
        // A rebuilt package with the same version replaces the previous one.
        try manager.installPackage(at: fixture.packageURL)

        let snapshot = try #require(manager.snapshots.first { $0.id == fixture.manifest.id })
        #expect(snapshot.origin == .localDevelopment)
        #expect(snapshot.requiresRestart)
    }

    @Test
    func rollbackVerifiesEachVersionWithTheOriginItWasInstalledWith() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let store = MacPluginPackageStore(
            rootURL: fixture.root.appendingPathComponent("installed", isDirectory: true),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
                allowsLocalDevelopmentPackages: true,
                hostBundleURL: fixture.hostBundleURL
            )
        )
        let signedUpdate = try fixture.makePackage(version: PluginVersion(major: 0, minor: 3, patch: 1))
        try fixture.sign(packageAt: signedUpdate.url, manifest: signedUpdate.manifest, keyID: "test-publisher-v1")

        // Development package first, then the signed release package.
        try store.installPackage(from: fixture.packageURL, origin: .localDevelopment)
        let updated = try store.installPackage(from: signedUpdate.url, origin: .marketplace)
        #expect(updated.installation.origin == .marketplace)
        #expect(updated.installation.previousOrigin == .localDevelopment)

        // Rolling back restores the unsigned package under its own origin.
        let restored = try store.rollback(fixture.manifest.id)
        #expect(restored.manifest.version == fixture.manifest.version)
        #expect(restored.installation.origin == .localDevelopment)
        #expect(restored.installation.previousOrigin == .marketplace)

        // And rolling forward again verifies the signed package as signed.
        let reapplied = try store.rollback(fixture.manifest.id)
        #expect(reapplied.manifest.version == signedUpdate.manifest.version)
        #expect(reapplied.installation.origin == .marketplace)
        #expect(reapplied.installation.previousOrigin == .localDevelopment)
        #expect(try store.scanInstalledPlugins().issues.isEmpty)
    }

    @Test
    func onlyPackagesThatRequireAPublisherSignatureCanBeDevelopmentPackages() throws {
        let publisherFixture = try PluginTrustFixture(signatureRequirement: .publisherPackage)
        defer { publisherFixture.remove() }
        let teamFixture = try PluginTrustFixture(signatureRequirement: .sameTeamAsHost)
        defer { teamFixture.remove() }

        #expect(MacOfficialPluginSignatureVerifier.isUnsignedDevelopmentPackage(
            at: publisherFixture.packageURL,
            manifest: publisherFixture.manifest
        ))
        // A same-team package never carries a publisher signature, so an
        // unsigned one is a normal package rather than a development package.
        #expect(!MacOfficialPluginSignatureVerifier.isUnsignedDevelopmentPackage(
            at: teamFixture.packageURL,
            manifest: teamFixture.manifest
        ))
        try publisherFixture.signPackage(keyID: "test-publisher-v1")
        #expect(!MacOfficialPluginSignatureVerifier.isUnsignedDevelopmentPackage(
            at: publisherFixture.packageURL,
            manifest: publisherFixture.manifest
        ))

        // A development origin cannot relax a same-team package's checks:
        // outside the host bundle it has no trust anchor at all.
        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: [:],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: teamFixture.hostBundleURL
        )
        #expect(throws: PluginPackageStoreError.hostSealRequired(teamFixture.manifest.id)) {
            try verifier.verify(
                packageAt: teamFixture.packageURL,
                manifest: teamFixture.manifest,
                origin: .localDevelopment
            )
        }
    }

    @Test
    func signatureDocumentInASameTeamPackageIsVerified() throws {
        let fixture = try PluginTrustFixture(signatureRequirement: .sameTeamAsHost)
        defer { fixture.remove() }
        let untrustedKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        try fixture.sign(
            packageAt: fixture.packageURL,
            manifest: fixture.manifest,
            keyID: "test-forged",
            privateKey: untrustedKey
        )
        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.invalidPackageSignature(
            PluginPackageSignature.Error.untrustedKey("test-forged").localizedDescription
        )) {
            try verifier.verify(packageAt: fixture.packageURL, manifest: fixture.manifest, origin: .marketplace)
        }
    }
}

struct NodeLanguageToolEnvironmentTests {
    @Test
    func nodeFromVersionManagersIsDiscoveredNewestFirst() {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let executables: Set<String> = [
            "/fixture-home/.nvm/versions/node/v9.11.2/bin/node",
            "/fixture-home/.nvm/versions/node/v24.14.0/bin/node",
            "/fixture-home/.nvm/versions/node/v18.20.8/bin/node"
        ]
        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: home,
            isExecutable: { executables.contains($0.path) },
            directoryNames: { url in
                url.path == "/fixture-home/.nvm/versions/node"
                    ? ["v9.11.2", "v24.14.0", "notes", "v18.20.8"]
                    : []
            }
        )

        let candidates = discovery.candidates(for: "node", projectURL: nil, environment: ["PATH": "/usr/bin:/bin"])

        #expect(candidates.map(\.executableURL.path) == [
            "/fixture-home/.nvm/versions/node/v24.14.0/bin/node",
            "/fixture-home/.nvm/versions/node/v18.20.8/bin/node",
            "/fixture-home/.nvm/versions/node/v9.11.2/bin/node"
        ])
    }

    @Test
    @MainActor
    func languageToolEnvironmentCarriesTheDiscoveredNodeExecutable() {
        let node = URL(fileURLWithPath: "/fixture-tools/node")
        let service = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: ["PATH": "/usr/bin:/bin"]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(node: node)
        )

        #expect(service.languageToolProcessEnvironment()["LITHE_NODE_PATH"] == node.path)
    }

    @Test
    @MainActor
    func languageToolEnvironmentNeverSelectsAProjectProvidedNode() {
        let projectNode = RuntimeToolCandidate(
            command: "node",
            executableURL: URL(fileURLWithPath: "/untrusted-project/.lithe/bin/node"),
            source: .project,
            detail: ".lithe/bin/node"
        )
        let homebrewNode = RuntimeToolCandidate(
            command: "node",
            executableURL: URL(fileURLWithPath: "/fixture-homebrew/bin/node"),
            source: .homebrew,
            detail: nil
        )
        let withGlobalNode = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: ["PATH": "/usr/bin:/bin"]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(candidates: [projectNode, homebrewNode])
        )
        let projectNodeOnly = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: ["PATH": "/usr/bin:/bin"]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(candidates: [projectNode])
        )

        #expect(withGlobalNode.languageToolProcessEnvironment()["LITHE_NODE_PATH"] == homebrewNode.executableURL.path)
        #expect(projectNodeOnly.languageToolProcessEnvironment()["LITHE_NODE_PATH"] == nil)
    }

    @Test
    @MainActor
    func explicitNodePathOverrideIsPreserved() {
        let service = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: [
                "PATH": "/usr/bin:/bin",
                "LITHE_NODE_PATH": "/custom/node"
            ]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(node: URL(fileURLWithPath: "/fixture-tools/node"))
        )

        #expect(service.languageToolProcessEnvironment()["LITHE_NODE_PATH"] == "/custom/node")
    }

    @Test
    @MainActor
    func declaredRuntimeToolIsExportedAndPutOnTheServerPath() {
        let go = RuntimeToolCandidate(
            command: "go",
            executableURL: URL(fileURLWithPath: "/fixture-homebrew/bin/go"),
            source: .homebrew,
            detail: nil
        )
        let service = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: ["PATH": "/usr/bin:/bin"]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(candidates: [go])
        )

        let environment = service.languageToolProcessEnvironment(runtimeTools: ["go"])

        #expect(environment["LITHE_GO_PATH"] == "/fixture-homebrew/bin/go")
        #expect(environment["PATH"] == "/fixture-homebrew/bin:/usr/bin:/bin")
        #expect(service.languageToolProcessEnvironment()["PATH"] == "/usr/bin:/bin")
    }

    @Test
    @MainActor
    func declaredRuntimeToolNeverComesFromTheProject() {
        let projectGo = RuntimeToolCandidate(
            command: "go",
            executableURL: URL(fileURLWithPath: "/untrusted-project/.lithe/bin/go"),
            source: .project,
            detail: ".lithe/bin/go"
        )
        let service = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: ["PATH": "/usr/bin:/bin"]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(candidates: [projectGo])
        )

        let environment = service.languageToolProcessEnvironment(runtimeTools: ["go"])

        #expect(environment["LITHE_GO_PATH"] == nil)
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }
}

private struct PluginTrustFixture {
    let root: URL
    let packageURL: URL
    /// Stands in for the host application bundle; fixture packages live
    /// outside it, so only publisher signatures can make them trusted.
    var hostBundleURL: URL { root.appendingPathComponent("host/Lithe.app") }
    let manifest: PluginManifest
    let privateKey: Curve25519.Signing.PrivateKey
    let signatureRequirement: PluginSignatureRequirement

    init(signatureRequirement: PluginSignatureRequirement = .publisherPackage) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-trust-\(UUID().uuidString)", isDirectory: true)
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        self.signatureRequirement = signatureRequirement
        let version = PluginVersion(major: 0, minor: 3, patch: 0)
        packageURL = root.appendingPathComponent("sources/\(version)", isDirectory: true)
        do {
            manifest = try Self.manifest(version: version, signatureRequirement: signatureRequirement)
            try FileManager.default.createDirectory(at: hostBundleURL, withIntermediateDirectories: true)
            try Self.writePackage(at: packageURL, version: version, signatureRequirement: signatureRequirement)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Writes another version of the same plugin next to the primary package.
    func makePackage(version: PluginVersion) throws -> (url: URL, manifest: PluginManifest) {
        let url = root.appendingPathComponent("sources/\(version)", isDirectory: true)
        let manifest = try Self.manifest(version: version, signatureRequirement: signatureRequirement)
        try Self.writePackage(at: url, version: version, signatureRequirement: signatureRequirement)
        return (url, manifest)
    }

    func signPackage(keyID: String) throws {
        try sign(packageAt: packageURL, manifest: manifest, keyID: keyID)
    }

    func sign(
        packageAt url: URL,
        manifest: PluginManifest,
        keyID: String,
        privateKey signingKey: Curve25519.Signing.PrivateKey? = nil
    ) throws {
        let document = try PluginPackageSignature.makeDocument(
            packageAt: url,
            pluginID: manifest.id.rawValue,
            pluginVersion: manifest.version.description,
            privateKey: signingKey ?? privateKey,
            keyID: keyID
        )
        try PluginPackageSignature.write(document, to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func manifest(
        version: PluginVersion,
        signatureRequirement: PluginSignatureRequirement
    ) throws -> PluginManifest {
        try DeclarativePluginTestSupport.descriptor(manifestObject(
            version: version,
            signatureRequirement: signatureRequirement
        )).pluginManifest
    }

    private static func manifestObject(
        version: PluginVersion,
        signatureRequirement: PluginSignatureRequirement
    ) -> [String: Any] {
        DeclarativePluginTestSupport.manifestObject(
            id: "dev.example.publisher",
            version: version,
            signatureRequirement: signatureRequirement,
            packagedLauncher: "language-server/bin/fixture"
        )
    }

    private static func writePackage(
        at packageURL: URL,
        version: PluginVersion,
        signatureRequirement: PluginSignatureRequirement
    ) throws {
        try DeclarativePluginTestSupport.writePackage(
            at: packageURL,
            manifest: manifestObject(version: version, signatureRequirement: signatureRequirement)
        )
    }
}

private final class PluginLocalDevelopmentKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private struct NodeEnvironmentTestRuntimeLocator: RuntimeLocator {
    let environmentValues: [String: String]

    init(environment: [String: String]) {
        environmentValues = environment
    }

    func environment() -> [String: String] { environmentValues }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private struct FixedNodeToolDiscovery: RuntimeToolDiscovery {
    let nodeCandidates: [RuntimeToolCandidate]

    init(node: URL) {
        nodeCandidates = [RuntimeToolCandidate(command: "node", executableURL: node, source: .environment, detail: nil)]
    }

    init(candidates: [RuntimeToolCandidate]) {
        nodeCandidates = candidates
    }

    func candidates(for command: String, projectURL: URL?, environment: [String: String]) -> [RuntimeToolCandidate] {
        nodeCandidates.filter { $0.command == command }
    }

    func guidance(for command: String, projectURL: URL?, environment: [String: String]) -> RuntimeToolGuidance {
        DefaultRuntimeToolDiscovery().guidance(for: command, projectURL: projectURL, environment: environment)
    }
}
