import Darwin
import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

struct DocumentHardLinkTests {
    @Test func hardLinkedTextOpensAndWatcherStillRecognizesItsIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let details = try #require(try files.readDocumentDetails(from: fixture.file, encoding: nil))
        #expect(details.text == Fixture.original)
        #expect(details.encoding == .utf8)
        let change = try await files.readDocumentChangeAsync(from: fixture.file, encoding: .utf8, knownIdentity: details.identity)
        guard case .unchanged = change else { Issue.record("Unchanged hard links must not trigger reloads"); return }
        try fixture.expectContents(Fixture.original, linked: Fixture.original)
    }

    @Test func ordinarySaveRequiresConsentBeforeCreatingStagingOrChangingEitherLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        _ = try authorization(files, fixture: fixture, mode: .replaceCurrentPath)
        try fixture.expectContents(Fixture.original, linked: Fixture.original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == ["alias.xml", "pom.xml"])
    }

    @Test(arguments: [DocumentHardLinkSaveMode.replaceCurrentPath, .updateLinkedFile])
    func confirmedSaveHasTheChosenLinkSemantics(mode: DocumentHardLinkSaveMode) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let consent = try authorization(files, fixture: fixture, mode: mode)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? NSNumber
        guard case .saved = try files.writeDocumentText("new", to: fixture.file, expectedContent: Fixture.original,
            encoding: .utf8, expectedIdentity: nil, hardLinkAuthorization: consent) else {
            Issue.record("Confirmed save should succeed"); return
        }
        try fixture.expectContents("new", linked: mode == .updateLinkedFile ? "new" : Fixture.original)
        let fileInfo = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        let aliasInfo = try FileManager.default.attributesOfItem(atPath: fixture.alias.path)
        #expect(((fileInfo[.systemFileNumber] as? NSNumber) == (aliasInfo[.systemFileNumber] as? NSNumber)) == (mode == .updateLinkedFile))
        #expect((fileInfo[.referenceCount] as? NSNumber)?.intValue == (mode == .updateLinkedFile ? 2 : 1))
        #expect(fileInfo[.posixPermissions] as? NSNumber == permissions)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 2)
    }

    @Test(arguments: [DocumentHardLinkSaveMode.replaceCurrentPath, .updateLinkedFile])
    func externalEditAfterConsentIsStillAConflict(mode: DocumentHardLinkSaveMode) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let consent = try authorization(files, fixture: fixture, mode: mode)
        try Data("external".utf8).write(to: fixture.alias)
        guard case .conflict(let text, _) = try files.writeDocumentText("mine", to: fixture.file, expectedContent: Fixture.original,
            encoding: .utf8, expectedIdentity: nil, hardLinkAuthorization: consent) else {
            Issue.record("Consent must not override the byte baseline"); return
        }
        #expect(text == "external")
        try fixture.expectContents("external", linked: "external")
    }

    @Test(arguments: ["", String(repeating: "x", count: 1024), "\u{4e2d}\u{6587}"])
    func inPlaceSaveGrowsAndTruncatesSharedBytesUsingTheSelectedEncoding(text: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let consent = try authorization(files, fixture: fixture, mode: .updateLinkedFile)
        guard case .saved(let identity) = try files.writeDocumentText(text, to: fixture.file, expectedContent: Fixture.original,
            encoding: .gbk, expectedIdentity: nil, hardLinkAuthorization: consent) else {
            Issue.record("Confirmed in-place save should succeed"); return
        }
        let expected = try MacDocumentEncoding.encode(text, encoding: .gbk)
        #expect(try Data(contentsOf: fixture.file) == expected)
        #expect(try Data(contentsOf: fixture.alias) == expected)
        #expect(identity == MacDocumentEncoding.identity(expected))
    }

    @Test(arguments: [DocumentHardLinkSaveMode.replaceCurrentPath, .updateLinkedFile])
    func replacingTheTargetWithIdenticalBytesInvalidatesConsent(mode: DocumentHardLinkSaveMode) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let consent = try authorization(files, fixture: fixture, mode: mode)
        try FileManager.default.removeItem(at: fixture.file)
        try Data(Fixture.original.utf8).write(to: fixture.file)
        #expect(throws: DocumentFileAccessError.hardLinkChanged) {
            _ = try files.writeDocumentText("mine", to: fixture.file, expectedContent: Fixture.original,
                encoding: .utf8, expectedIdentity: nil, hardLinkAuthorization: consent)
        }
        try fixture.expectContents(Fixture.original, linked: Fixture.original)
    }

    @Test func changedLinkCountInvalidatesConsentAndTrashRetainsItsSingleLinkGuard() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let consent = try authorization(files, fixture: fixture, mode: .updateLinkedFile)
        try FileManager.default.linkItem(at: fixture.file, to: fixture.directory.appendingPathComponent("third.xml"))
        #expect(throws: DocumentFileAccessError.hardLinkChanged) {
            _ = try files.writeDocumentText("mine", to: fixture.file, expectedContent: Fixture.original,
                encoding: .utf8, expectedIdentity: nil, hardLinkAuthorization: consent)
        }
        #expect(throws: DocumentFileAccessError.hardLinkMutationUnsupported) {
            _ = try files.trashDocument(at: fixture.file, expectedIdentity: MacDocumentEncoding.identity(Data(Fixture.original.utf8)))
        }
        try fixture.expectContents(Fixture.original, linked: Fixture.original)
    }

    @Test func directoriesSymbolicLinksAndPipesHaveDistinctReadFailures() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        let symbolic = fixture.directory.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fixture.file)
        let pipe = fixture.directory.appendingPathComponent("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: DocumentFileAccessError.directory) { _ = try files.readDocumentText(from: fixture.directory) }
        #expect(throws: DocumentFileAccessError.symbolicLink) { _ = try files.readDocumentText(from: symbolic) }
        #expect(throws: DocumentFileAccessError.notRegularFile) { _ = try files.readDocumentText(from: pipe) }
        #expect(try files.readDocumentText(from: fixture.directory.appendingPathComponent("missing")) == nil)
    }

    @Test func permissionSizeAndDecodeFailuresRemainDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = MacWorkspaceFileOperations()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path) }
        do {
            _ = try files.readDocumentText(from: fixture.file)
            Issue.record("Unreadable file must fail")
        } catch { #expect(StandaloneFileOpenFailure(error: error) == .permissionDenied) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
        let handle = try FileHandle(forWritingTo: fixture.file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 32 * 1024 * 1024 + 1)
        #expect(throws: CocoaError(.fileReadTooLarge)) { _ = try files.readDocumentText(from: fixture.file) }
        try Data([0xFF, 0xFE, 0x41]).write(to: fixture.file)
        #expect(throws: CocoaError(.fileReadInapplicableStringEncoding)) { _ = try files.readDocumentText(from: fixture.file) }
    }

    private func authorization(_ files: MacWorkspaceFileOperations, fixture: Fixture, mode: DocumentHardLinkSaveMode) throws -> DocumentHardLinkAuthorization {
        do {
            _ = try files.writeDocumentText("mine", to: fixture.file, expectedContent: Fixture.original)
            throw CocoaError(.featureUnsupported)
        } catch let required as DocumentHardLinkConfirmationRequired {
            return .init(targetIdentity: required.targetIdentity, mode: mode)
        }
    }

    private struct Fixture {
        static let original = "<project><modelVersion>4.1.0</modelVersion></project>"
        let directory: URL
        let file: URL
        let alias: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            file = directory.appendingPathComponent("pom.xml")
            alias = directory.appendingPathComponent("alias.xml")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try Data(Self.original.utf8).write(to: file)
                try FileManager.default.linkItem(at: file, to: alias)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }

        func expectContents(_ text: String, linked: String) throws {
            #expect(try String(contentsOf: file, encoding: .utf8) == text)
            #expect(try String(contentsOf: alias, encoding: .utf8) == linked)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
