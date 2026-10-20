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

    /// Two central records imply six directories plus two files. Both public
    /// extraction paths must reject this before creating an extraction root.
    @Test(arguments: [false, true])
    func implicitDirectoriesAreRefusedBeforeExtraction(throughDownload: Bool) async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("implicit-directories")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("implicit.zip")
        try Self.emptyStoredZIP(paths: ["one/a/b/file", "two/a/b/file"]).write(to: archive)
        let limits = MacPluginPackageDownloader.Limits(archiveBytes: 4096, extractedBytes: 0, entries: 5)
        try MacPluginPackageDownloader.checkDeclaredContents(
            of: archive, limits: .init(archiveBytes: 4096, extractedBytes: 0, entries: 8)
        )
        let extractionRoot = root.appendingPathComponent("extract", isDirectory: true)
        let downloader = Self.downloader(serving: archive, into: extractionRoot, limits: limits)
        let expected = MacPluginPackageDownloadError.extractionLimitExceeded("more than 5 files")
        #expect(throws: expected) {
            try MacPluginPackageDownloader.checkDeclaredContents(of: archive, limits: limits)
        }
        if throughDownload {
            await #expect(throws: expected) {
                _ = try await downloader.download(
                    archiveURL: Self.archiveURL,
                    expectedSHA256: try MacPluginPackageDownloader.sha256(of: archive),
                    pluginID: PluginID("io.example.bomb")
                )
            }
        } else {
            #expect(throws: expected) { try downloader.extractArchive(archive, into: extractionRoot) }
        }
        #expect(!FileManager.default.fileExists(atPath: extractionRoot.path))
    }

    /// Explicit directory records may precede or follow children. Shared
    /// parents count once, while an empty directory still consumes one object.
    @Test(arguments: [false, true])
    func explicitAndImplicitDirectoriesShareTheObjectBudget(directoriesFirst: Bool) throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("directory-budget")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("directories.zip")
        let files = ["shared/branch/one", "shared/branch/two"]
        let directories = ["shared/", "shared/branch/", "empty/"]
        try Self.emptyStoredZIP(paths: directoriesFirst ? directories + files : files + directories).write(to: archive)
        try MacPluginPackageDownloader.checkDeclaredContents(
            of: archive, limits: .init(archiveBytes: 4096, extractedBytes: 0, entries: 5)
        )
        // Omitting shared directories leaves only three central records, but
        // still describes the same five filesystem objects.
        try Self.emptyStoredZIP(paths: files + ["empty/"]).write(to: archive)
        try MacPluginPackageDownloader.checkDeclaredContents(
            of: archive, limits: .init(archiveBytes: 4096, extractedBytes: 0, entries: 5)
        )
        #expect(throws: MacPluginPackageDownloadError.extractionLimitExceeded("more than 4 files")) {
            try MacPluginPackageDownloader.checkDeclaredContents(
                of: archive, limits: .init(archiveBytes: 4096, extractedBytes: 0, entries: 4)
            )
        }
    }

    /// Prefix strings can cost more than the ZIP headers that describe them,
    /// even when both file count and payload size are comfortably in budget.
    @Test(arguments: [false, true])
    func cumulativePathBytesAreRefusedBeforeExtraction(throughDownload: Bool) async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("path-budget")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("paths.zip")
        let path = (Array(repeating: String(repeating: "a", count: 60), count: 5) + ["file"]).joined(separator: "/")
        let data = Self.emptyStoredZIP(paths: [path])
        #expect(data.count < 1000)
        try data.write(to: archive)
        try MacPluginPackageDownloader.checkDeclaredContents(
            of: archive, limits: .init(archiveBytes: 2000, extractedBytes: 0, entries: 10)
        )
        let extractionRoot = root.appendingPathComponent("extract", isDirectory: true)
        let limits = MacPluginPackageDownloader.Limits(archiveBytes: 1000, extractedBytes: 0, entries: 10)
        let downloader = Self.downloader(serving: archive, into: extractionRoot, limits: limits)
        let expected = MacPluginPackageDownloadError.extractionLimitExceeded("more than 1000 path bytes")
        if throughDownload {
            await #expect(throws: expected) {
                _ = try await downloader.download(
                    archiveURL: Self.archiveURL,
                    expectedSHA256: try MacPluginPackageDownloader.sha256(of: archive),
                    pluginID: PluginID("io.example.bomb")
                )
            }
        } else {
            #expect(throws: expected) { try downloader.extractArchive(archive, into: extractionRoot) }
        }
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

    /// Valid stored ZIPs containing only empty files/directories. Unlike a ZIP
    /// tool, this writer never inserts the omitted parent directory records.
    private static func emptyStoredZIP(paths: [String]) -> Data {
        var output = Data()
        var central = Data()
        func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        for path in paths {
            let name = Data(path.utf8)
            let offset = UInt32(output.count)
            output.append(u32(0x04034b50))
            output.append(u16(20))
            output.append(u16(0)); output.append(u16(0)) // flags, stored
            output.append(u16(0)); output.append(u16(0)) // time, date
            output.append(u32(0)); output.append(u32(0)); output.append(u32(0)) // CRC, sizes
            output.append(u16(UInt16(name.count))); output.append(u16(0))
            output.append(name)
            central.append(u32(0x02014b50))
            central.append(u16(20)); central.append(u16(20))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(0)); central.append(u32(0)); central.append(u32(0))
            central.append(u16(UInt16(name.count))); central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(0)); central.append(u32(offset)); central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(u32(0x06054b50))
        output.append(u16(0)); output.append(u16(0))
        output.append(u16(UInt16(paths.count))); output.append(u16(UInt16(paths.count)))
        output.append(u32(UInt32(central.count))); output.append(u32(centralOffset)); output.append(u16(0))
        return output
    }

    /// Understates regular-file sizes while retaining valid zero-byte directory
    /// entries, so extraction reaches the measured-size guard with a valid ZIP.
    private static func understateSizes(of archive: URL, to output: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: archive))
        var index = 0
        while index + 46 <= bytes.count {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4b, bytes[index + 2] == 0x01, bytes[index + 3] == 0x02 {
                let nameLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
                if nameLength > 0, index + 46 + nameLength <= bytes.count,
                   bytes[index + 46 + nameLength - 1] != 0x2f {
                    bytes.replaceSubrange((index + 24)..<(index + 28), with: [1, 0, 0, 0])
                }
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
