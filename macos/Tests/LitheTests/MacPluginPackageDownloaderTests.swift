import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

struct MacPluginPackageDownloaderTests {
    /// The release archive holds a declarative (schema 2) package. The
    /// downloader must verify the index checksum, find the package by `id`,
    /// and hand it to the package store, which performs the full validation.
    @Test
    func downloadedDeclarativePackageIsFoundAndInstallable() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("download")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/dev.lithe.plugin.php-support", isDirectory: true)
        try DeclarativePluginTestSupport.writeOfficialPackage("PhpSupport", at: source)
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("php.zip"))
        let downloader = MacPluginPackageDownloader(
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [
                "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/t/php.zip": archive
            ]),
            temporaryDirectory: root
        )

        let downloaded = try await downloader.download(
            archiveURL: URL(string: "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/t/php.zip")!,
            expectedSHA256: try MacPluginPackageDownloader.sha256(of: archive),
            pluginID: OfficialPluginCatalog.phpPluginID
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

    /// Nothing from an archive that differs from the index is extracted.
    @Test
    func checksumMismatchIsRefusedBeforeExtraction() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("checksum")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/dev.lithe.plugin.php-support", isDirectory: true)
        try DeclarativePluginTestSupport.writeOfficialPackage("PhpSupport", at: source)
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("php.zip"))
        let extractionRoot = root.appendingPathComponent("extract", isDirectory: true)
        let url = "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/t/php.zip"
        let downloader = MacPluginPackageDownloader(
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [url: archive]),
            temporaryDirectory: extractionRoot
        )
        let expected = String(repeating: "0", count: 64)

        await #expect(throws: MacPluginPackageDownloadError.checksumMismatch(
            expected: expected,
            actual: try MacPluginPackageDownloader.sha256(of: archive)
        )) {
            _ = try await downloader.download(
                archiveURL: URL(string: url)!,
                expectedSHA256: expected,
                pluginID: OfficialPluginCatalog.phpPluginID
            )
        }
        #expect(!FileManager.default.fileExists(atPath: extractionRoot.path))
    }

    /// A matching checksum only proves the archive is the one the index
    /// named; a third-party index can still name a ZIP bomb.
    @Test
    func archiveDeclaringTooMuchIsRefusedBeforeExtraction() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("declared")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/io.example.bomb", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: source.appendingPathComponent("zeros.bin"))
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("bomb.zip"))
        let extractionRoot = root.appendingPathComponent("extract", isDirectory: true)

        let sizeError = await #expect(throws: MacPluginPackageDownloadError.self) {
            _ = try await Self.downloader(serving: archive, into: extractionRoot, limits: .init(
                archiveBytes: 1_048_576, extractedBytes: 4 * 1024, entries: 100
            )).download(
                archiveURL: Self.archiveURL,
                expectedSHA256: try MacPluginPackageDownloader.sha256(of: archive),
                pluginID: PluginID("io.example.bomb")
            )
        }
        #expect(Self.isLimitExceeded(sizeError))
        let countError = #expect(throws: MacPluginPackageDownloadError.self) {
            try MacPluginPackageDownloader.checkDeclaredContents(
                of: archive,
                limits: .init(archiveBytes: 1_048_576, extractedBytes: 1_048_576, entries: 1)
            )
        }
        #expect(Self.isLimitExceeded(countError))
        // Nothing was extracted, not even the extraction directory.
        #expect(!FileManager.default.fileExists(atPath: extractionRoot.path))
    }

    /// `ditto` trusts the data, not the directory, so an archive that
    /// understates its sizes is stopped by measuring what was written.
    @Test
    func archiveUnderstatingItsSizeIsStoppedWhileExtracting() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("understated")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/io.example.bomb", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: source.appendingPathComponent("zeros.bin"))
        let honest = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("honest.zip"))
        let archive = root.appendingPathComponent("lying.zip")
        try Self.understateSizes(of: honest, to: archive)
        let limits = MacPluginPackageDownloader.Limits(archiveBytes: 1_048_576, extractedBytes: 4 * 1024, entries: 100)
        // The directory now passes the declared check.
        try MacPluginPackageDownloader.checkDeclaredContents(of: archive, limits: limits)

        let extractionTemp = root.appendingPathComponent("extract", isDirectory: true)
        let error = await #expect(throws: MacPluginPackageDownloadError.self) {
            _ = try await Self.downloader(serving: archive, into: extractionTemp, limits: limits).download(
                archiveURL: Self.archiveURL,
                expectedSHA256: try MacPluginPackageDownloader.sha256(of: archive),
                pluginID: PluginID("io.example.bomb")
            )
        }
        #expect(Self.isLimitExceeded(error))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: extractionTemp.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    /// The limit applies while bytes arrive: a response without a declared
    /// length is cut off at the limit and leaves no file behind.
    @Test
    func urlSessionTransportStopsStreamingPastTheLimit() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("stream")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixedBodyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = MacURLSessionPluginMarketplaceTransport(session: session, temporaryDirectory: root)

        let small = try await transport.download(from: FixedBodyURLProtocol.url(bytes: 512), maximumBytes: 1024)
        #expect(try Data(contentsOf: small).count == 512)

        try FileManager.default.removeItem(at: small)
        await #expect(throws: MacPluginPackageDownloadError.archiveTooLarge(1024)) {
            _ = try await transport.download(from: FixedBodyURLProtocol.url(bytes: 64 * 1024), maximumBytes: 1024)
        }
        await #expect(throws: MacPluginPackageDownloadError.archiveTooLarge(1024)) {
            _ = try await transport.download(
                from: FixedBodyURLProtocol.url(bytes: 64 * 1024, declaresLength: true),
                maximumBytes: 1024
            )
        }
        // Neither cut-off download left a partial file behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test
    func urlSessionTransportRefusesPlainHTTP() async {
        let transport = MacURLSessionPluginMarketplaceTransport()
        await #expect(throws: MacPluginPackageDownloadError.invalidEndpoint) {
            _ = try await transport.download(
                from: URL(string: "http://github.com/example/plugin.zip")!,
                maximumBytes: 1
            )
        }
    }

    private static let archiveURL = URL(string: "https://github.com/example/bomb/releases/download/v1/bomb.zip")!

    private static func downloader(
        serving archive: URL,
        into temporaryDirectory: URL,
        limits: MacPluginPackageDownloader.Limits
    ) -> MacPluginPackageDownloader {
        MacPluginPackageDownloader(
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [archiveURL.absoluteString: archive]),
            temporaryDirectory: temporaryDirectory,
            limits: limits
        )
    }

    /// Rewrites every central-directory uncompressed size to 1 byte, leaving
    /// the compressed data intact.
    private static func understateSizes(of archive: URL, to output: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: archive))
        var index = 0
        while index + 46 <= bytes.count {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4b, bytes[index + 2] == 0x01, bytes[index + 3] == 0x02 {
                bytes.replaceSubrange((index + 24)..<(index + 28), with: [1, 0, 0, 0])
                index += 46
            } else {
                index += 1
            }
        }
        try Data(bytes).write(to: output)
    }

    private static func isLimitExceeded(_ error: MacPluginPackageDownloadError?) -> Bool {
        if case .extractionLimitExceeded? = error { true } else { false }
    }
}

/// Serves `https://fixture.invalid/<bytes>` as that many zero bytes, with or
/// without a Content-Length header, so the transport's limit is exercised
/// without a network.
private final class FixedBodyURLProtocol: URLProtocol {
    static func url(bytes: Int, declaresLength: Bool = false) -> URL {
        URL(string: "https://fixture.invalid/\(bytes)\(declaresLength ? "?length" : "")")!
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let count = Int(url.lastPathComponent) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var headers: [String: String] = [:]
        if url.query == "length" {
            headers["Content-Length"] = String(count)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Several chunks, like a real body.
        let chunk = Data(count: 4096)
        var sent = 0
        while sent < count {
            let size = min(chunk.count, count - sent)
            client?.urlProtocol(self, didLoad: chunk.prefix(size))
            sent += size
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
