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
