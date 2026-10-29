import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LitheSearchModule
import Testing
@testable import Lithe

@MainActor
struct DocumentOpenAndHardLinkWorkflowTests {
    @Test(arguments: [DocumentHardLinkSaveMode.replaceCurrentPath, .updateLinkedFile])
    func explicitSaveUsesOnlyTheChoiceConfirmedForThisWrite(mode: DocumentHardLinkSaveMode) async throws {
        let files = Files()
        var prompts = 0
        let feature = makeFeature(files: files, confirm: { _ in prompts += 1; return mode })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        #expect(!document.isReadOnly)
        document.applyLiveEditorText("edited")
        try await feature.save(document)
        #expect(prompts == 1)
        #expect(files.savedModes == [mode])
        #expect(!document.isDirty)
        document.applyLiveEditorText("edited again")
        try await feature.save(document)
        #expect(prompts == 2)
        #expect(files.savedModes == [mode, mode])
    }

    @Test func cancellationKeepsTheDraftAndNeitherSavesNorReportsSuccess() async throws {
        let files = Files()
        var messages: [String] = []
        let feature = makeFeature(files: files, notify: { messages.append($0) })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        await feature.saveEditorDocument(document)?.value
        #expect(files.savedModes.isEmpty)
        #expect(document.text == "unsaved")
        #expect(document.isDirty)
        #expect(document.lifecycleState.status != .saving)
        #expect(messages.isEmpty)
    }

    @Test func autoSaveNeverPresentsOrRemembersHardLinkConsent() async throws {
        let files = Files()
        var prompts = 0
        var messages: [String] = []
        let feature = makeFeature(files: files, autoSave: true,
            confirm: { _ in prompts += 1; return .updateLinkedFile }, notify: { messages.append($0) })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        await feature.documentDidChange(document)?.value
        #expect(prompts == 0)
        #expect(files.savedModes.isEmpty)
        #expect(document.isDirty)
        #expect(messages.count == 1)
        try await feature.save(document)
        document.applyLiveEditorText("later unsaved")
        await feature.documentDidChange(document)?.value
        #expect(prompts == 1)
        #expect(files.savedModes == [.updateLinkedFile])
        #expect(document.isDirty)
    }

    @Test func cancellingTheHardLinkChoiceAlsoCancelsCloseWithoutLosingEdits() async throws {
        let files = Files()
        var messages: [String] = []
        let feature = makeFeature(files: files, notify: { messages.append($0) })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        feature.requestCloseDocument(document)
        await feature.closePendingDocument(discardingChanges: false)?.value
        #expect(feature.openDocuments.contains { $0 === document })
        #expect(document.isDirty)
        #expect(files.savedModes.isEmpty)
        #expect(messages.isEmpty)
    }

    @Test func cancellingTheChoiceBeforeEncodingReopenKeepsTheDraftAndEncoding() async throws {
        let files = Files()
        var messages: [String] = []
        let feature = makeFeature(files: files, notify: { messages.append($0) })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        await feature.requestReopen(document, with: .gbk)?.value
        #expect(feature.pendingEncodingReopen != nil)
        await feature.resolvePendingEncodingReopen(saveChanges: true)?.value
        #expect(document.text == "unsaved")
        #expect(document.isDirty)
        #expect(document.readEncoding == .utf8)
        #expect(files.savedModes.isEmpty)
        #expect(messages.isEmpty)
    }

    @Test(arguments: [false, true])
    func updatingAllLinksReconcilesOpenAliasesWithoutOverwritingTheirDrafts(dirtyAlias: Bool) async throws {
        let files = Files(updatesSharedContents: true)
        let reconciled = TestGate()
        let aliasURL = URL(fileURLWithPath: "/in-memory/alias.xml")
        let feature = makeFeature(files: files, confirm: { _ in .updateLinkedFile }, onChanged: {
            if $0.url == aliasURL { reconciled.open() }
        })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        await feature.openFileAsync(aliasURL, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        let alias = try #require(feature.activeDocument)
        if dirtyAlias { alias.applyLiveEditorText("alias draft") }
        document.applyLiveEditorText("shared update")
        try await feature.save(document)
        #expect(await reconciled.waitUntilOpen(), "Shared-file save did not reconcile the other open path")
        #expect(alias.text == (dirtyAlias ? "alias draft" : "shared update"))
        #expect(alias.isDirty == dirtyAlias)
        #expect(alias.hasExternalConflict == dirtyAlias)
    }

    @Test(arguments: [false, true])
    func failedSharedWriteKeepsDraftsWarnsAboutPartialContentsAndReconcilesAliases(closing: Bool) async throws {
        let files = Files(updatesSharedContents: true, authorizedFailure: DocumentFileAccessError.inPlaceWriteFailed)
        let reconciled = TestGate()
        let aliasURL = URL(fileURLWithPath: "/in-memory/alias.xml")
        var messages: [String] = []
        let feature = makeFeature(files: files, confirm: { _ in .updateLinkedFile }, notify: { messages.append($0) },
            onChanged: { if $0.url == aliasURL { reconciled.open() } })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        await feature.openFileAsync(aliasURL, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        let alias = try #require(feature.activeDocument)
        alias.applyLiveEditorText("alias draft")
        document.applyLiveEditorText("shared update")
        if closing {
            feature.requestCloseDocument(document)
            await feature.closePendingDocument(discardingChanges: false)?.value
        } else {
            await feature.saveEditorDocument(document)?.value
        }
        #expect(await reconciled.waitUntilOpen(), "Failed shared write did not reconcile aliases")
        #expect(feature.openDocuments.contains { $0 === document })
        #expect(document.text == "shared update")
        #expect(document.isDirty)
        #expect(alias.text == "alias draft")
        #expect(alias.hasExternalConflict)
        #expect(messages == [L10n.string("The shared file could not be fully saved. All hard links may contain partial changes. Your editor contents are retained; check the file before retrying.")])
    }

    @Test func nativeWritePermissionErrorsExplainTheFailureAndKeepTheDraft() async throws {
        let files = Files(authorizedFailure: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)))
        var messages: [String] = []
        let feature = makeFeature(files: files, confirm: { _ in .updateLinkedFile }, notify: { messages.append($0) })
        defer { feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        await feature.saveEditorDocument(document)?.value
        #expect(document.isDirty)
        #expect(document.text == "unsaved")
        #expect(messages == [String(format: L10n.string("Could not save %@: permission denied. Check the file and parent folder permissions. Your edits are still unsaved."), "pom.xml")])
    }

    @Test func anEditDuringTheModalChoiceInvalidatesConsent() async throws {
        let files = Files()
        var document: EditorDocument?
        let feature = makeFeature(files: files, confirm: { _ in
            document?.applyLiveEditorText("newer input")
            return .updateLinkedFile
        })
        defer { feature.reset() }
        await open(feature)
        document = feature.activeDocument
        let opened = try #require(document)
        opened.applyLiveEditorText("old input")
        await #expect(throws: CancellationError.self) { try await feature.save(opened) }
        #expect(files.savedModes.isEmpty)
        #expect(opened.text == "newer input")
        #expect(opened.isDirty)
    }

    @Test(arguments: [
        (CocoaError(.fileReadNoPermission) as NSError, StandaloneFileOpenFailure.permissionDenied),
        (CocoaError(.fileReadTooLarge) as NSError, .tooLarge),
        (CocoaError(.fileReadInapplicableStringEncoding) as NSError, .decodingFailed),
        (CocoaError(.fileReadUnknown) as NSError, .readFailed),
        (CocoaError(.fileReadNoSuchFile) as NSError, .unavailable),
        (NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue)), .permissionDenied),
    ])
    func readFailuresRetainTheirCategoryAndNeverInvokeABinaryViewer(error: NSError, failure: StandaloneFileOpenFailure) async {
        let registry = BinaryFileViewerRegistry()
        var binaryOpens = 0
        registry.register(.init(identifier: "test", fileExtensions: ["xml"], open: { _ in binaryOpens += 1 }))
        let files = Files(failure: error)
        var messages: [String] = []
        let feature = makeFeature(files: files, registry: registry, notify: { messages.append($0) })
        defer { feature.reset() }
        await open(feature)
        #expect(StandaloneFileOpenFailure(error: error) == failure)
        #expect(feature.activeDocument == nil)
        #expect(binaryOpens == 0)
        #expect(messages.count == 1)
        #expect(messages.first?.contains(failure.title) == true)
        #expect(messages.first?.contains("pom.xml") == true)
        #expect(messages.first?.contains(StandaloneFileOpenFailure.notText.title) == false)
    }

    @Test(arguments: [false, true])
    func decodingFailureOnlyOpensABinaryViewerForAKnownSignature(hasKnownSignature: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("probe.xml")
        let magic = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try (hasKnownSignature ? magic : Data("not a known binary signature".utf8)).write(to: url)
        let registry = BinaryFileViewerRegistry()
        var opens = 0
        var messages: [String] = []
        registry.register(.init(identifier: "test", fileExtensions: ["xml"],
            magicSignatures: [.init(bytes: magic)], open: { _ in opens += 1 }))
        let feature = makeFeature(files: Files(failure: CocoaError(.fileReadInapplicableStringEncoding)), registry: registry,
            notify: { messages.append($0) }, storage: MacFileStorage(), workspace: directory)
        defer { feature.reset() }
        await feature.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        #expect(feature.activeDocument == nil)
        #expect(opens == (hasKnownSignature ? 1 : 0))
        #expect(messages.count == (hasKnownSignature ? 0 : 1))
        if !hasKnownSignature { #expect(messages.first?.contains(StandaloneFileOpenFailure.decodingFailed.title) == true) }
    }

    @Test func standaloneOpenUsesTheSameHardLinkSaveChoice() async throws {
        let files = Files()
        var prompts = 0
        let feature = makeFeature(files: files, confirm: { _ in prompts += 1; return .replaceCurrentPath })
        let completed = TestGate()
        let subscription = feature.$standaloneFileLoadState.sink { state in
            if state != .loading && state != .idle { completed.open() }
        }
        defer { subscription.cancel(); feature.reset() }
        feature.openStandaloneFile(URL(fileURLWithPath: "/in-memory/pom.xml"))
        #expect(await completed.waitUntilOpen())
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("standalone edit")
        try await feature.save(document)
        #expect(prompts == 1)
        #expect(files.savedModes == [.replaceCurrentPath])
    }

    @Test func standaloneDecodingFailureIsNotReportedAsNonText() async {
        let feature = makeFeature(files: Files(failure: CocoaError(.fileReadInapplicableStringEncoding)))
        let completed = TestGate()
        let subscription = feature.$standaloneFileLoadState.sink { state in
            if state != .loading && state != .idle { completed.open() }
        }
        defer { subscription.cancel(); feature.reset() }
        feature.openStandaloneFile(URL(fileURLWithPath: "/in-memory/pom.xml"))
        #expect(await completed.waitUntilOpen())
        #expect(feature.standaloneFileLoadState == .failed(.decodingFailed))
        #expect(feature.activeDocument == nil)
    }

    private func open(_ feature: DocumentFeatureModel) async {
        await feature.openFileAsync(URL(fileURLWithPath: "/in-memory/pom.xml"),
            isReadOnly: false, displayPath: nil, activateWhenReady: true)
    }

    private func makeFeature(
        files: Files, autoSave: Bool = false,
        registry: BinaryFileViewerRegistry = BinaryFileViewerRegistry(),
        confirm: @escaping @MainActor (URL) -> DocumentHardLinkSaveMode? = { _ in nil },
        notify: @escaping @MainActor (String) -> Void = { _ in },
        onChanged: @escaping @MainActor (EditorDocument) -> Void = { _ in },
        storage: any FileStorage = UnavailableFileStorage(), workspace: URL = URL(fileURLWithPath: "/in-memory")
    ) -> DocumentFeatureModel {
        let feature = DocumentFeatureModel(operations: EmptyOperations(),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: files, fileStorage: storage, binaryFileViewerRegistry: registry,
            confirmHardLinkSave: confirm, autoSaveDelay: { _ in })
        feature.configure(workspaceURLProvider: { workspace },
            autoSaveEnabledProvider: { autoSave }, autoSaveDelayProvider: { 0 }, notify: notify,
            onDocumentOpened: { _ in }, onDocumentChanged: onChanged, onDocumentClosed: { _ in },
            onRecordSave: { _, _ in }, onRecordDiscard: { _ in }, onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {}, onProjectCloseReady: {})
        return feature
    }

    private final class Files: WorkspaceFileOperations, @unchecked Sendable {
        private let failure: Error?
        private let updatesSharedContents: Bool
        private let authorizedFailure: Error?
        private let lock = NSLock()
        private var modes: [DocumentHardLinkSaveMode] = []
        private var sharedText = "original"
        private var sharedIdentity = "bytes"
        var savedModes: [DocumentHardLinkSaveMode] { lock.withLock { modes } }
        init(failure: Error? = nil, updatesSharedContents: Bool = false, authorizedFailure: Error? = nil) {
            self.failure = failure
            self.updatesSharedContents = updatesSharedContents
            self.authorizedFailure = authorizedFailure
        }
        var supportsDocumentEncoding: Bool { true }
        func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
            if let failure { throw failure }
            return lock.withLock { DocumentReadDetails(text: sharedText, encoding: .utf8, identity: sharedIdentity) }
        }
        func readDocumentDetailsAsync(from url: URL, encoding: DocumentEncoding?) async throws -> DocumentReadDetails? {
            try readDocumentDetails(from: url, encoding: encoding)
        }
        func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding,
            expectedIdentity: String?) async throws -> EncodedDocumentWriteResult {
            throw DocumentHardLinkConfirmationRequired(targetIdentity: "target")
        }
        func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding,
            expectedIdentity: String?, hardLinkAuthorization: DocumentHardLinkAuthorization) async throws -> EncodedDocumentWriteResult {
            #expect(hardLinkAuthorization.targetIdentity == "target")
            return try lock.withLock {
                modes.append(hardLinkAuthorization.mode)
                if updatesSharedContents, hardLinkAuthorization.mode == .updateLinkedFile {
                    sharedText = text
                    sharedIdentity = "updated bytes"
                }
                if let authorizedFailure { throw authorizedFailure }
                return .saved(identity: sharedIdentity)
            }
        }
        func fileExists(at url: URL) -> Bool { true }
        func isDirectory(at url: URL) -> Bool { false }
        func createFile(at url: URL) throws {}
        func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
        func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
        func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
        func removeItem(at url: URL) throws {}
        func trashItem(at url: URL) throws {}
        func writeText(_ text: String, to url: URL) throws {}
        func readText(from url: URL) throws -> String { "original" }
    }

    private struct EmptyOperations: WorkspaceOperations {
        func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }
        func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: FileVisibilityRules) -> [FileSearchResult]? { nil }
        func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: FileVisibilityRules) -> SearchEverywhereResults? { nil }
        func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: FileVisibilityRules) -> [ProjectReplacementFile]? { nil }
        func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
        func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
    }
}
