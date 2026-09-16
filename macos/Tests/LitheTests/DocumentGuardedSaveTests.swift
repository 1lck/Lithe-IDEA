import Foundation
import Testing
@testable import Lithe

struct DocumentGuardedSaveTests {
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
