import Foundation
import Testing
@testable import Lithe

struct DocumentGuardedSaveTests {
    @Test func watcherIdentityIsCheckedBeforeDecodingWithCurrentReadEncoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("GBK.txt")
        try Data([0xD6, 0xD0, 0xCE, 0xC4]).write(to: url)
        let files = MacWorkspaceFileOperations()
        let details = try #require(try files.readDocumentDetails(from: url, encoding: .gbk))

        let result = try await files.readDocumentChangeAsync(
            from: url, encoding: .utf8, knownIdentity: details.identity
        )
        guard case .unchanged = result else {
            Issue.record("A self-save notification must not decode unchanged bytes")
            return
        }
    }

    @Test func documentEncodingAutoDetectsGBKAndPreservesIdentity() throws {
        try withFile { url, files in
            let bytes = Data([0xD6, 0xD0, 0xCE, 0xC4, 0x0A])
            try bytes.write(to: url)
            guard let details = try files.readDocumentDetails(from: url, encoding: nil) else {
                Issue.record("Expected decoded GBK details")
                return
            }
            #expect(details.text == "中文\n")
            #expect(details.encoding == .gbk)
            #expect(details.identity?.count == 64)
        }
    }

    @Test func explicitUTF8ReopenShowsReplacementCharactersForGBKBytes() throws {
        try withFile { url, files in
            try Data([0xD6, 0xD0, 0xCE, 0xC4]).write(to: url)
            guard let details = try files.readDocumentDetails(from: url, encoding: .utf8) else {
                Issue.record("Expected explicitly decoded UTF-8 details")
                return
            }
            #expect(details.text.contains("\u{FFFD}"))
            #expect(details.text != "中文")
            #expect(details.encoding == .utf8)
        }
    }

    @Test func documentEncodingExplicitGB18030RoundTrips() throws {
        try withFile { url, files in
            let source = "中文𠀀\n"
            guard case .saved = try files.writeDocumentText(
                source, to: url, expectedContent: nil, encoding: .gb18030, expectedIdentity: nil
            ) else { Issue.record("Expected GB18030 save"); return }
            guard let details = try files.readDocumentDetails(from: url, encoding: .gb18030) else {
                Issue.record("Expected decoded GB18030 details")
                return
            }
            #expect(details.text == source)
            #expect(details.encoding == .gb18030)
        }
    }

    @Test(arguments: [
        (DocumentEncoding.utf16LEBom, [UInt8]([0xFF, 0xFE])),
        (DocumentEncoding.utf16BEBom, [UInt8]([0xFE, 0xFF])),
    ])
    func documentEncodingAutoDetectsUTF16ByBOMAndRoundTripsIt(encoding: DocumentEncoding, bom: [UInt8]) throws {
        try withFile { url, files in
            let source = "<html>数据库文档 😀</html>\n"
            guard case .saved = try files.writeDocumentText(
                source, to: url, expectedContent: nil, encoding: encoding, expectedIdentity: nil
            ) else { Issue.record("Expected UTF-16 save"); return }
            #expect(Array(try Data(contentsOf: url).prefix(2)) == bom)
            guard let details = try files.readDocumentDetails(from: url, encoding: nil) else {
                Issue.record("Expected auto-detected UTF-16 details")
                return
            }
            #expect(details.text == source)
            #expect(details.encoding == encoding)
        }
    }

    // The byte vectors match the Windows backend's test so both platforms write identical files.
    @Test(arguments: [
        (DocumentEncoding.utf16LE, "A中", [UInt8]([0x41, 0x00, 0x2D, 0x4E])),
        (DocumentEncoding.utf16BE, "A中", [UInt8]([0x00, 0x41, 0x4E, 0x2D])),
        (DocumentEncoding.big5, "中文", [UInt8]([0xA4, 0xA4, 0xA4, 0xE5])),
        (DocumentEncoding.eucJP, "日本", [UInt8]([0xC6, 0xFC, 0xCB, 0xDC])),
        (DocumentEncoding.eucKR, "한글", [UInt8]([0xC7, 0xD1, 0xB1, 0xDB])),
        (DocumentEncoding.windows1250, "Łódź", [UInt8]([0xA3, 0xF3, 0x64, 0x9F])),
        (DocumentEncoding.windows1251, "Привет", [UInt8]([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])),
        (DocumentEncoding.koi8R, "Привет", [UInt8]([0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4])),
    ])
    func documentEncodingWritesAndReadsCommonEncodingsExplicitly(
        encoding: DocumentEncoding, text: String, bytes: [UInt8]
    ) throws {
        try withFile { url, files in
            guard case .saved = try files.writeDocumentText(
                text, to: url, expectedContent: nil, encoding: encoding, expectedIdentity: nil
            ) else { Issue.record("Expected \(encoding) save"); return }
            #expect(Array(try Data(contentsOf: url)) == bytes)
            let details = try files.readDocumentDetails(from: url, encoding: encoding)
            #expect(details?.text == text)
            #expect(details?.encoding == encoding)
        }
    }

    @Test func documentEncodingRejectsCharactersMissingFromTheTargetCodec() throws {
        try withFile { url, files in
            for (encoding, text) in [(DocumentEncoding.windows1251, "中"), (.big5, "한")] {
                #expect(throws: CocoaError.self) {
                    _ = try files.writeDocumentText(
                        text, to: url, expectedContent: nil, encoding: encoding, expectedIdentity: nil
                    )
                }
            }
        }
    }

    @Test func documentEncodingCatalogHasSixteenUniqueStableIDs() {
        #expect(DocumentEncoding.catalog.count == 16)
        for descriptor in DocumentEncoding.catalog {
            #expect(DocumentEncoding.catalog.filter { $0.stableID == descriptor.stableID }.count == 1)
        }
    }

    @Test func documentEncodingDoesNotMistakeUTF32LEBOMForUTF16() throws {
        try withFile { url, files in
            // "A" as UTF-32 LE with BOM: its first two bytes equal the UTF-16 LE mark.
            try Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]).write(to: url)
            #expect(throws: CocoaError.self) { _ = try files.readDocumentDetails(from: url, encoding: nil) }
            // An explicit reopen still reaches the ambiguous UTF-16 reading.
            let details = try files.readDocumentDetails(from: url, encoding: .utf16LEBom)
            #expect(details?.encoding == .utf16LEBom)
        }
    }

    @Test func documentEncodingRejectsInvalidUTF16AutomaticallyButRepairsOnExplicitReopen() throws {
        try withFile { url, files in
            // Odd length: a dangling byte after one complete code unit.
            try Data([0xFF, 0xFE, 0x41, 0x00, 0x42]).write(to: url)
            #expect(throws: CocoaError.self) { _ = try files.readDocumentDetails(from: url, encoding: nil) }
            #expect(try files.readDocumentDetails(from: url, encoding: .utf16LEBom)?.text == "A\u{FFFD}")
            // Unpaired high surrogate.
            try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: url)
            #expect(throws: CocoaError.self) { _ = try files.readDocumentDetails(from: url, encoding: nil) }
            #expect(try files.readDocumentDetails(from: url, encoding: .utf16LEBom)?.text == "\u{FFFD}")
        }
    }

    @Test func documentEncodingRejectsUnrepresentableTextBeforeWriting() throws {
        try withFile { url, files in
            try Data("before".utf8).write(to: url)
            #expect(throws: CocoaError.self) {
                _ = try files.writeDocumentText(
                    "中文", to: url, expectedContent: "before", encoding: .windows1252, expectedIdentity: nil
                )
            }
            #expect(try Data(contentsOf: url) == Data("before".utf8))
        }
    }

    @Test func documentEncodingUsesRawIdentityForConflicts() throws {
        try withFile { url, files in
            let utf8 = Data("中文".utf8)
            try utf8.write(to: url)
            guard let initial = try files.readDocumentDetails(from: url, encoding: .utf8) else {
                Issue.record("Expected initial UTF-8 details")
                return
            }
            try Data([0xD6, 0xD0, 0xCE, 0xC4]).write(to: url)
            let result = try files.writeDocumentText(
                "mine", to: url, expectedContent: initial.text,
                encoding: .utf8, expectedIdentity: initial.identity
            )
            guard case .conflict(_, let identity) = result else {
                Issue.record("Expected a raw-byte conflict")
                return
            }
            #expect(identity != initial.identity)
        }
    }

    private func withFile(_ body: (URL, MacWorkspaceFileOperations) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("A.java"), MacWorkspaceFileOperations())
    }

    @Test func externalChangeWithSameSizeAndMtimeIsNotOverwritten() throws {
        try withFile { url, files in
            try Data("old".utf8).write(to: url)
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            try Data("new".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            let result = try files.writeDocumentText("mine", to: url, expectedContent: "old")
            guard case .conflict(let disk) = result else { Issue.record("Expected conflict"); return }
            #expect(disk == "new")
            #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        }
    }

    @Test func missingFileRequiresExplicitRecreation() throws {
        try withFile { url, files in
            let result = try files.writeDocumentText("mine", to: url, expectedContent: "old")
            guard case .conflict(let disk) = result else { Issue.record("Expected missing-file conflict"); return }
            #expect(disk == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            guard case .saved = try files.writeDocumentText("mine", to: url, expectedContent: nil) else {
                Issue.record("Explicit recreation failed"); return
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
        }
    }

    @Test func successfulSaveInvalidatesAnotherWindowsBaselineAndCleansStaging() throws {
        try withFile { url, files in
            try Data("old".utf8).write(to: url)
            guard case .saved = try files.writeDocumentText("first", to: url, expectedContent: "old") else {
                Issue.record("Save should succeed"); return
            }
            guard case .conflict = try files.writeDocumentText("second", to: url, expectedContent: "old") else {
                Issue.record("Stale window must conflict"); return
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "first")
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["A.java"])
        }
    }

    @Test func canonicalEquivalentUnicodeIsStillDifferentDiskBytes() throws {
        try withFile { url, files in
            try Data("e\u{301}".utf8).write(to: url)
            guard case .conflict = try files.writeDocumentText("mine", to: url, expectedContent: "é") else {
                Issue.record("Unicode canonical equivalence must not hide byte changes"); return
            }
        }
    }
}
