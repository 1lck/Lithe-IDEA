import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Lithe

struct MacPluginDiskPackageImporterTests {
    @Test
    func directoryImportOwnsIndependentSnapshotAndPreservesExecutableResources() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-directory")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Example", isDirectory: true)
        try Self.writePackage(at: source)
        let executable = source.appendingPathComponent("server")
        try Data("original executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let before = try Self.treeContents(source)
        let imports = root.appendingPathComponent("imports", isDirectory: true)

        let imported = try await MacPluginDiskPackageImporter(temporaryDirectory: imports).importPackage(at: source)
        defer { try? FileManager.default.removeItem(at: imported.temporaryDirectory) }
        #expect(imported.fileName == "Example")
        #expect(imported.archiveSHA256 == nil)
        #expect(imported.temporaryDirectory.lastPathComponent.hasPrefix("lithe-plugin-disk-"))
        #expect(try Self.treeContents(source) == before)
        #expect(try Self.treeContents(imported.packageURL) == before)
        let mode = try FileManager.default.attributesOfItem(atPath: imported.packageURL.appendingPathComponent("server").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)

        try Data("changed after review".utf8).write(to: executable)
        try FileManager.default.removeItem(at: source.appendingPathComponent("plugin.json"))
        #expect(try Self.treeContents(imported.packageURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path) == [imported.temporaryDirectory.lastPathComponent])
    }

    @Test
    func ZIPUsesActualSnapshotSHAAndManifestRatherThanFilename() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-zip")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/unrelated-directory", isDirectory: true)
        try Self.writePackage(at: source)
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("unrelated-name.zip"))
        let archiveBytes = try Data(contentsOf: archive)
        let expectedSHA = SHA256.hash(data: archiveBytes).map { String(format: "%02x", $0) }.joined()
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let imported = try await MacPluginDiskPackageImporter(temporaryDirectory: imports).importPackage(at: archive)
        defer { try? FileManager.default.removeItem(at: imported.temporaryDirectory) }

        #expect(imported.fileName == "unrelated-name.zip")
        #expect(imported.archiveSHA256 == expectedSHA)
        #expect(imported.packageURL.lastPathComponent == "unrelated-directory")
        #expect(try Data(contentsOf: archive) == archiveBytes)
        try Data("replacement".utf8).write(to: archive)
        #expect(try Data(contentsOf: imported.temporaryDirectory.appendingPathComponent("archive.zip")) == archiveBytes)
        #expect(try Data(contentsOf: imported.packageURL.appendingPathComponent("plugin.json")) == Self.manifest)
    }

    @Test
    func ZIPWithManifestAtArchiveRootIsAccepted() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-flat-zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("flat.zip")
        try Self.storedZIP([.init(path: "plugin.json", data: Self.manifest)]).write(to: archive)
        let imported = try await MacPluginDiskPackageImporter(temporaryDirectory: root).importPackage(at: archive)
        defer { try? FileManager.default.removeItem(at: imported.temporaryDirectory) }
        #expect(imported.packageURL.lastPathComponent == "package")
        #expect(try Data(contentsOf: imported.packageURL.appendingPathComponent("plugin.json")) == Self.manifest)
    }

    @Test
    func everyManifestCountsEvenWhenHiddenOrInvalidAndFailuresCleanSnapshots() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-manifests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let importer = MacPluginDiskPackageImporter(temporaryDirectory: imports)
        for paths in [
            ["one/plugin.json", "two/plugin.json"],
            ["plugin.json", ".hidden/plugin.json"],
            ["deep/nested/plugin.json"],
            ["readme.txt"]
        ] {
            let archive = root.appendingPathComponent("\(UUID().uuidString).zip")
            try Self.storedZIP(paths.map { .init(path: $0, data: Data("invalid JSON".utf8)) }).write(to: archive)
            await #expect(throws: MacPluginPackageDownloadError.invalidArchive) {
                _ = try await importer.importPackage(at: archive)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
        }
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try Self.writePackage(at: directory)
        try Self.writePackage(at: directory.appendingPathComponent(".hidden", isDirectory: true))
        await #expect(throws: MacPluginPackageDownloadError.invalidArchive) {
            _ = try await importer.importPackage(at: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
    }

    @Test
    func ZIPPathsLinksSpecialFilesAndConflictingLocalNamesAreRejectedBeforeExtraction() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-unsafe-zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let escape = "lithe-disk-escape-\(UUID().uuidString)"
        let escaped = root.appendingPathComponent(escape)
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let importer = MacPluginDiskPackageImporter(temporaryDirectory: imports)
        let cases: [[ZIPEntry]] = [
            [.init(path: "../../\(escape)")],
            [.init(path: escaped.path)],
            [.init(path: "folder/../plugin.json")],
            [.init(path: "C:\\outside\\plugin.json")],
            [.init(path: "link", data: Data("../outside".utf8), mode: 0o120777)],
            [.init(path: "fifo", mode: 0o010644)],
            [.init(path: "plugin.json", localPath: "../outside")],
            [.init(path: "plugin.json"), .init(path: "PLUGIN.JSON")],
            [.init(path: "folder"), .init(path: "folder/plugin.json")],
            [.init(path: "folder/plugin.json"), .init(path: "folder")]
        ]
        for entries in cases {
            let archive = root.appendingPathComponent("\(UUID().uuidString).zip")
            try Self.storedZIP(entries).write(to: archive)
            // The shared preflight itself fails, so no unsafe path reaches ditto.
            #expect(throws: MacPluginPackageDownloadError.invalidArchive) {
                try MacPluginPackageDownloader.checkDeclaredContents(of: archive, limits: .standard)
            }
            await #expect(throws: MacPluginPackageDownloadError.invalidArchive) {
                _ = try await importer.importPackage(at: archive)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test
    func directorySymlinksFIFOsAndRootAliasesAreRefusedWithoutTouchingTheirTargets() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-links")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try Self.writePackage(at: source)
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside")
        let sentinel = Data("outside is read-only".utf8)
        try sentinel.write(to: target)
        let importer = MacPluginDiskPackageImporter(temporaryDirectory: imports)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await #expect(throws: MacPluginDiskPackageImportError.unsafeEntry) {
            _ = try await importer.importPackage(at: source)
        }
        try FileManager.default.removeItem(at: link)
        // A directory link must not be traversed, even if its target is a valid package.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: MacPluginDiskPackageImportError.unsafeEntry) {
            _ = try await importer.importPackage(at: source)
        }
        try FileManager.default.removeItem(at: link)
        let fifo = source.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: MacPluginDiskPackageImportError.unsafeEntry) {
            _ = try await importer.importPackage(at: source)
        }
        try FileManager.default.removeItem(at: fifo)
        let rootLink = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: source)
        await #expect(throws: MacPluginDiskPackageImportError.unsafeEntry) {
            _ = try await importer.importPackage(at: rootLink)
        }
        await #expect(throws: MacPluginDiskPackageImportError.unsafeEntry) {
            _ = try await importer.importPackage(at: URL(fileURLWithPath: rootLink.path, isDirectory: true))
        }
        let alias = root.appendingPathComponent("source-alias.zip")
        try Data("Finder alias".utf8).write(to: alias)
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x80
        try #require(finderInfo.withUnsafeBytes {
            setxattr(alias.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0)
        } == 0)
        await #expect(throws: MacPluginDiskPackageImportError.unsafeEntry) {
            _ = try await importer.importPackage(at: alias)
        }
        #expect(try Data(contentsOf: target) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
    }

    @Test
    func excessiveDirectoryDepthAndTemporaryRootInsideSourceAreRejected() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-depth")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try Self.writePackage(at: source)
        var nested = source
        for _ in 0..<65 {
            nested.appendPathComponent("d", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        }
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let error = await #expect(throws: MacPluginPackageDownloadError.self) {
            _ = try await MacPluginDiskPackageImporter(temporaryDirectory: imports).importPackage(at: source)
        }
        #expect(Self.isLimitExceeded(error))
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
        let insideSource = source.appendingPathComponent("snapshots", isDirectory: true)
        await #expect(throws: MacPluginDiskPackageImportError.unsupportedSource) {
            _ = try await MacPluginDiskPackageImporter(temporaryDirectory: insideSource).importPackage(at: source)
        }
        #expect(!FileManager.default.fileExists(atPath: insideSource.path))
    }

    @Test
    func archiveAndDirectorySizeAndEntryLimitsLeaveNoPartialSnapshot() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try Self.writePackage(at: source)
        try Data(count: 1024).write(to: source.appendingPathComponent("large.bin"))
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("large.zip"))
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        await #expect(throws: MacPluginPackageDownloadError.archiveTooLarge(32)) {
            _ = try await MacPluginDiskPackageImporter(temporaryDirectory: imports, limits: .init(
                archiveBytes: 32, extractedBytes: 4096, entries: 100
            )).importPackage(at: archive)
        }
        for candidate in [source, archive] {
            let sizeError = await #expect(throws: MacPluginPackageDownloadError.self) {
                _ = try await MacPluginDiskPackageImporter(temporaryDirectory: imports, limits: .init(
                    archiveBytes: 4096, extractedBytes: 512, entries: 100
                )).importPackage(at: candidate)
            }
            #expect(Self.isLimitExceeded(sizeError))
            let countError = await #expect(throws: MacPluginPackageDownloadError.self) {
                _ = try await MacPluginDiskPackageImporter(temporaryDirectory: imports, limits: .init(
                    archiveBytes: 4096, extractedBytes: 4096, entries: 1
                )).importPackage(at: candidate)
            }
            #expect(Self.isLimitExceeded(countError))
            #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
        }
    }

    @Test
    func understatedZIPStillHitsActualExtractionLimitAndCleansUp() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-understated")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("understated.zip")
        try Self.storedZIP([
            .init(path: "plugin.json", data: Self.manifest),
            .init(path: "large.bin", data: Data(count: 64 * 1024), declaredSize: 1)
        ]).write(to: archive)
        let limits = MacPluginPackageDownloader.Limits(archiveBytes: 128 * 1024, extractedBytes: 512, entries: 100)
        try MacPluginPackageDownloader.checkDeclaredContents(of: archive, limits: limits)
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let error = await #expect(throws: MacPluginPackageDownloadError.self) {
            _ = try await MacPluginDiskPackageImporter(temporaryDirectory: imports, limits: limits).importPackage(at: archive)
        }
        #expect(Self.isLimitExceeded(error))
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
    }

    @Test
    func cancellationAfterOwnedDirectoryCreationRemovesSnapshot() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("disk-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try Self.writePackage(at: source)
        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let importer = MacPluginDiskPackageImporter(
            temporaryDirectory: imports, fileManager: CancellingSnapshotFileManager()
        )
        // The test double cancels the current task immediately after creating
        // its owned directory. No sleeps, racing tasks or private-state polling.
        let task = Task {
            try await importer.importPackage(at: source)
        }
        defer { task.cancel() }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
    }

    private static let manifest = Data("{\"id\":\"io.example.fixture\"}".utf8)

    private static func writePackage(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("plugin.json"))
    }

    private static func treeContents(_ root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let components = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                try #require(Array(components.prefix(rootComponents.count)) == rootComponents)
                result[components.dropFirst(rootComponents.count).joined(separator: "/")] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private static func isLimitExceeded(_ error: MacPluginPackageDownloadError?) -> Bool {
        if case .extractionLimitExceeded? = error { true } else { false }
    }

    private struct ZIPEntry {
        let path: String
        var data = Data()
        var mode: UInt32 = 0o100644
        var localPath: String? = nil
        var declaredSize: UInt32? = nil
    }

    /// Small stored ZIPs make unsafe headers deterministic, without invoking an
    /// unbounded process or depending on archive tools that sanitize the input.
    private static func storedZIP(_ entries: [ZIPEntry]) -> Data {
        var output = Data()
        var central = Data()
        func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        for entry in entries {
            let name = Data(entry.path.utf8)
            let localName = Data((entry.localPath ?? entry.path).utf8)
            let offset = UInt32(output.count)
            let size = UInt32(entry.data.count)
            let checksum = crc32(entry.data)
            output.append(u32(0x04034b50))
            output.append(u16(20))
            output.append(u16(0)) // flags
            output.append(u16(0)) // stored
            output.append(u16(0)); output.append(u16(0))
            output.append(u32(checksum)); output.append(u32(size)); output.append(u32(size))
            output.append(u16(UInt16(localName.count))); output.append(u16(0))
            output.append(localName); output.append(entry.data)
            central.append(u32(0x02014b50))
            central.append(u16(0x0314)); central.append(u16(20))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(checksum)); central.append(u32(size)); central.append(u32(entry.declaredSize ?? size))
            central.append(u16(UInt16(name.count))); central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(entry.mode << 16)); central.append(u32(offset)); central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(u32(0x06054b50))
        output.append(u16(0)); output.append(u16(0))
        output.append(u16(UInt16(entries.count))); output.append(u16(UInt16(entries.count)))
        output.append(u32(UInt32(central.count))); output.append(u32(centralOffset)); output.append(u16(0))
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1 == 0) ? 0 : 0xedb8_8320) }
        }
        return ~crc
    }
}

private final class CancellingSnapshotFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(
        at url: URL, withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        if url.lastPathComponent.hasPrefix("lithe-plugin-disk-") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}
