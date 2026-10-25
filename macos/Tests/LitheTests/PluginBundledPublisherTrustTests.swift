import CryptoKit
import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning
import Testing

/// Runs production validation, signature verification and package storage.
/// No fixture process executes, and all files belong to this test's root.
struct PluginBundledPublisherTrustTests {
    @Test
    func hostSealedCopyAndSignedInstalledUpdateUseOnePluginIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.digest(of: fixture.bundled)
        let initial = try fixture.store().scanInstalledPlugins()
        #expect(initial.issues.isEmpty)
        #expect(initial.packages.map(\.installation.origin) == [.bundled])

        try fixture.sign(fixture.download)
        let installed = try fixture.store().installPackage(from: fixture.download)
        let restarted = try fixture.store().scanInstalledPlugins()
        #expect(restarted.issues.isEmpty)
        #expect(restarted.packages.count == 1)
        #expect(restarted.packages.first?.packageURL.resolvingSymlinksInPath() == installed.packageURL.resolvingSymlinksInPath())
        #expect(restarted.packages.first?.installation.origin == .marketplace)
        #expect(try fixture.digest(of: fixture.bundled) == before)
        #expect(try fixture.digest(of: installed.packageURL) == fixture.digest(of: fixture.download))
    }

    @Test
    func unsignedOutsideCopyCannotClaimTheBundledTrustException() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for origin: PluginInstallationOrigin in [.marketplace, .bundled, .localDevelopment] {
            #expect(throws: (any Error).self) {
                _ = try fixture.store().verifyCandidatePackage(
                    at: fixture.download, origin: origin, marketplace: nil
                )
            }
        }
        #expect(try fixture.store().scanInstalledPlugins().packages.first?.installation.origin == .bundled)
    }

    @Test
    func presentInvalidSignatureIsRejectedEvenInsideTheHostSeal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sign(fixture.bundled)
        try Data("tampered".utf8).write(to: fixture.bundled.appendingPathComponent("server.jar"))
        let scan = try fixture.store().scanInstalledPlugins()
        #expect(scan.packages.isEmpty)
        #expect(scan.issues.count == 1)
    }

    @Test
    func installedRuntimeTamperingCannotFallBackToHostSeal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sign(fixture.download)
        let installed = try fixture.store().installPackage(from: fixture.download)
        try Data("tampered".utf8).write(to: installed.packageURL.appendingPathComponent("runtime/arm64/bin/java"))
        let scan = try fixture.store().scanInstalledPlugins()
        #expect(scan.issues.count == 1)
        // The damaged update is isolated; the immutable bundled source remains.
        #expect(scan.packages.map(\.installation.origin) == [.bundled])
    }

    @Test
    func officialPackageCannotChangeItsPinnedBundledTrust() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var manifest = fixture.manifest
        var vendor = try #require(manifest["vendor"] as? [String: Any])
        vendor.removeValue(forKey: "bundledSignatureRequirement")
        manifest["vendor"] = vendor
        var requires = try #require(manifest["requires"] as? [String: Int])
        requires.removeValue(forKey: "packageTrust")
        manifest["requires"] = requires
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.download.appendingPathComponent("plugin.json"))
        try fixture.sign(fixture.download)
        #expect(throws: PluginPackageStoreError.officialSignatureRequirementMismatch(OfficialPluginCatalog.javaPluginID)) {
            _ = try fixture.store().installPackage(from: fixture.download)
        }
    }

    @Test
    func signedPackageMissingTheHostArchitectureRuntimeIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let arch = MacPluginLanguageServerLaunchResolver.hostArchitecture
        try FileManager.default.removeItem(at: fixture.download.appendingPathComponent("runtime/\(arch)/bin/java"))
        try fixture.sign(fixture.download)
        #expect(throws: (any Error).self) {
            _ = try fixture.store().installPackage(from: fixture.download)
        }
        #expect(try fixture.store().scanInstalledPlugins().packages.map(\.installation.origin) == [.bundled])
    }

    private struct Fixture {
        let root: URL
        let host: URL
        let bundled: URL
        let download: URL
        let manifest: [String: Any]
        let privateKey: Curve25519.Signing.PrivateKey

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-publisher-bundled-\(UUID().uuidString)")
            host = root.appendingPathComponent("Lithe.app")
            bundled = host.appendingPathComponent("Contents/Resources/OfficialPlugins/dev.lithe.plugin.java-support")
            download = root.appendingPathComponent("download/dev.lithe.plugin.java-support")
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
            let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/publisher-bundled.plugin.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["id"] = OfficialPluginCatalog.javaPluginID.rawValue
            manifest = object
            do {
                for package in [bundled, download] {
                    try DeclarativePluginTestSupport.writePackage(at: package, manifest: manifest)
                    for arch in ["arm64", "x86_64"] {
                        let java = package.appendingPathComponent("runtime/\(arch)/bin/java")
                        try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data("fixture runtime".utf8).write(to: java)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
                    }
                    try Data("fixture server".utf8).write(to: package.appendingPathComponent("server.jar"))
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func store() -> MacPluginPackageStore {
            MacPluginPackageStore(
                rootURL: root.appendingPathComponent("installed"),
                bundledRootURL: bundled.deletingLastPathComponent(),
                validator: DeclarativePluginTestSupport.operations,
                verifier: MacOfficialPluginSignatureVerifier(
                    trustedPublisherKeys: [PluginPackageSignature.keyID: privateKey.publicKey],
                    allowsLocalDevelopmentPackages: false,
                    hostBundleURL: host
                )
            )
        }

        func sign(_ package: URL) throws {
            let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
            let document = try PluginPackageSignature.makeDocument(
                packageAt: package,
                pluginID: descriptor.id.rawValue,
                pluginVersion: descriptor.pluginManifest.version.description,
                privateKey: privateKey
            )
            try PluginPackageSignature.write(document, to: package)
        }

        func digest(of package: URL) throws -> String {
            try PluginPackageSignature.contentDigest(packageAt: package, fileManager: FileManager.default)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
