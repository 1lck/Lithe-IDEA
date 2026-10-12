import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

struct MacPluginPackageDownloaderTests {
    @Test
    func officialPHPArchiveURLUsesTheAppReleaseVersionAndChannel() throws {
        let configuration = MacPluginDistributionConfiguration(
            releaseBaseURL: URL(string: "https://downloads.example.test/releases")!,
            channel: .stable,
            architecture: "arm64",
            releaseVersion: PluginVersion(major: 0, minor: 5, patch: 8)
        )

        let url = try configuration.archiveURL(pluginID: OfficialPluginCatalog.phpPluginID)

        #expect(url.absoluteString == "https://downloads.example.test/releases/v0.5.8/Lithe-PHP-Support-0.5.8-arm64.zip")
    }

    @Test
    func previewPHPArchiveURLUsesTheRollingPreviewTag() throws {
        let configuration = MacPluginDistributionConfiguration(
            releaseBaseURL: URL(string: "https://downloads.example.test/releases")!,
            channel: .preview,
            architecture: "x86_64",
            releaseVersion: PluginVersion(major: 0, minor: 3, patch: 0)
        )

        let url = try configuration.archiveURL(pluginID: OfficialPluginCatalog.phpPluginID)

        #expect(url.absoluteString == "https://downloads.example.test/releases/preview-0.3.0/Lithe-PHP-Support-0.3.0-x86_64.zip")
    }

    /// The release archive holds a declarative (schema 2) package. The
    /// downloader must find it by `id` and hand it to the package store,
    /// which performs the full validation.
    @Test
    func downloadedDeclarativePackageIsFoundAndInstallable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-download-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/dev.lithe.plugin.php-support", isDirectory: true)
        try DeclarativePluginTestSupport.writeOfficialPackage("PhpSupport", at: source)
        let archive = root.appendingPathComponent("Lithe-PHP-Support.zip")
        // The bounded runner terminates ditto if it outlives the timeout.
        let zip = MacProcessRunner().run(ProcessRequest(
            executablePath: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", source.path, archive.path],
            timeoutMilliseconds: 30_000
        ))
        try #require(zip.exitCode == 0, "\(zip.output)")

        let host = "downloads-\(UUID().uuidString.lowercased()).example.test"
        StubPluginArchiveProtocol.register(try Data(contentsOf: archive), host: host)
        defer { StubPluginArchiveProtocol.unregister(host: host) }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubPluginArchiveProtocol.self]
        let downloader = MacPluginPackageDownloader(
            configuration: MacPluginDistributionConfiguration(
                releaseBaseURL: URL(string: "https://\(host)/releases")!,
                channel: .stable,
                architecture: "arm64",
                releaseVersion: PluginVersion(major: 1, minor: 0, patch: 0)
            ),
            session: URLSession(configuration: sessionConfiguration),
            temporaryDirectory: root
        )

        let downloaded = try await downloader.download(
            pluginID: OfficialPluginCatalog.phpPluginID,
            hostVersion: PluginVersion(major: 1, minor: 0, patch: 0)
        )
        defer { try? FileManager.default.removeItem(at: downloaded.temporaryDirectory) }
        #expect(downloaded.packageURL.lastPathComponent == "dev.lithe.plugin.php-support")

        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: true,
                hostBundleURL: root.appendingPathComponent("host/Lithe.app", isDirectory: true)
            )
        )
        let installed = try store.installPackage(from: downloaded.packageURL, origin: .localDevelopment)
        #expect(installed.descriptor.id == OfficialPluginCatalog.phpPluginID)
        #expect(installed.descriptor.pluginManifest.entrypoint.kind == .declarative)
    }

    @Test
    func unsupportedPluginCannotBeMappedToThePHPArchive() {
        let configuration = MacPluginDistributionConfiguration(architecture: "arm64")

        #expect(throws: MacPluginPackageDownloadError.unsupportedPlugin(PluginID("dev.example.plugin"))) {
            _ = try configuration.archiveURL(pluginID: PluginID("dev.example.plugin"))
        }
    }
}

/// Serves a fixed archive for one host so download tests never reach the
/// network. Hosts are unique per test, which keeps parallel tests isolated.
private final class StubPluginArchiveProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var archives: [String: Data] = [:]

    static func register(_ data: Data, host: String) {
        lock.withLock { archives[host] = data }
    }

    static func unregister(host: String) {
        lock.withLock { archives[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { archives[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let data = Self.lock.withLock({ Self.archives[host] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
