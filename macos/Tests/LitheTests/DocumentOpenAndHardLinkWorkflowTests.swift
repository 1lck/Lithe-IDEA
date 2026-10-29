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

    @Test(arguments: [DocumentHardLinkSaveMode.replaceCurrentPath, .updateLinkedFile], [false, true])
    func explicitSaveTakesOverAnAutoSaveAwaitingHardLinkDetection(mode: DocumentHardLinkSaveMode, converting: Bool) async throws {
        let check = WriteCheck()
        let files = Files(firstWriteCheck: check)
        var prompts = 0
        let feature = makeFeature(files: files, autoSave: true, confirm: { _ in prompts += 1; return mode })
        defer { check.release.open(); feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("first draft")
        let automatic = try #require(feature.documentDidChange(document))
        defer { automatic.cancel() }
        try #require(await check.started.waitUntilOpen(), "Automatic hard-link detection did not start")
        let synchronized = observeNextSaveSynchronization(document)
        let explicit = Task { @MainActor in
            if converting { try await feature.save(document, encoding: .utf16LE) }
            else { try await feature.save(document) }
        }
        defer { explicit.cancel(); document.synchronizeEditor = nil }
        #expect(await synchronized.waitUntilOpen(), "Explicit save did not join the pending automatic save")
        #expect(prompts == 0)
        // New input before consent must be saved using the original disk baseline.
        document.applyLiveEditorText("latest draft")
        check.release.open()
        await automatic.value
        try await explicit.value
        #expect(prompts == 1)
        #expect(files.savedModes == [mode])
        #expect(files.writes.count == 3)
        #expect(files.writes.map(\.text) == ["first draft", "latest draft", "latest draft"])
        #expect(files.writes.allSatisfy { $0.baseline == "original" && $0.identity == "bytes" })
        #expect(files.writes.last?.encoding == (converting ? .utf16LE : .utf8))
        #expect(document.saveEncoding == (converting ? .utf16LE : .utf8))
        #expect(document.savedText == "latest draft")
        #expect(!document.isDirty)
    }

    @Test func cancellingOverlappingExplicitConsentKeepsTheDraft() async throws {
        let check = WriteCheck()
        let files = Files(firstWriteCheck: check)
        var prompts = 0
        let feature = makeFeature(files: files, autoSave: true, confirm: { _ in prompts += 1; return nil })
        defer { check.release.open(); feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        let automatic = try #require(feature.documentDidChange(document))
        defer { automatic.cancel() }
        try #require(await check.started.waitUntilOpen())
        let synchronized = observeNextSaveSynchronization(document)
        let explicit = Task { @MainActor in try await feature.save(document) }
        defer { explicit.cancel(); document.synchronizeEditor = nil }
        #expect(await synchronized.waitUntilOpen())
        check.release.open()
        await automatic.value
        await #expect(throws: CancellationError.self) { try await explicit.value }
        #expect(prompts == 1)
        #expect(files.savedModes.isEmpty)
        #expect(files.writes.count == 2)
        #expect(document.text == "unsaved")
        #expect(document.isDirty)
        #expect(document.lifecycleState.status != .saving)
    }

    @Test(arguments: ["cancel", "reset", "close", "relocate"])
    func obsoleteExplicitWaitersNeverRequestHardLinkConsent(ending: String) async throws {
        let check = WriteCheck()
        let files = Files(firstWriteCheck: check)
        var prompts = 0
        let feature = makeFeature(files: files, autoSave: true, confirm: { _ in prompts += 1; return .updateLinkedFile })
        defer { check.release.open(); feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        let automatic = try #require(feature.documentDidChange(document))
        defer { automatic.cancel() }
        try #require(await check.started.waitUntilOpen())
        let synchronized = observeNextSaveSynchronization(document)
        let explicit = Task { @MainActor in try await feature.save(document) }
        defer { explicit.cancel(); document.synchronizeEditor = nil }
        #expect(await synchronized.waitUntilOpen())
        switch ending {
        case "cancel": explicit.cancel()
        case "reset": feature.reset()
        case "close":
            document.synchronizeEditor = nil
            feature.requestCloseDocument(document)
            let close = try #require(feature.closePendingDocument(discardingChanges: true))
            defer { close.cancel() }
            await close.value
            #expect(!feature.openDocuments.contains { $0 === document })
        default:
            let originalURL = document.url
            document.relocate(to: originalURL.appendingPathExtension("moved"))
            document.relocate(to: originalURL)
        }
        check.release.open()
        await automatic.value
        await #expect(throws: CancellationError.self) { try await explicit.value }
        #expect(prompts == 0)
        #expect(files.savedModes.isEmpty)
        #expect(files.writes.count == 1)
        #expect(document.text == "unsaved")
    }

    @Test func overlappingExplicitSaveDoesNotRetryAnIOFailure() async throws {
        let check = WriteCheck(failure: CocoaError(.fileWriteNoPermission))
        let files = Files(firstWriteCheck: check)
        var prompts = 0
        let feature = makeFeature(files: files, autoSave: true, confirm: { _ in prompts += 1; return .updateLinkedFile })
        defer { check.release.open(); feature.reset() }
        await open(feature)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("unsaved")
        let automatic = try #require(feature.documentDidChange(document))
        defer { automatic.cancel() }
        try #require(await check.started.waitUntilOpen())
        let synchronized = observeNextSaveSynchronization(document)
        let explicit = Task { @MainActor in try await feature.save(document) }
        defer { explicit.cancel(); document.synchronizeEditor = nil }
        #expect(await synchronized.waitUntilOpen())
        check.release.open()
        await automatic.value
        await #expect(throws: CocoaError(.fileWriteNoPermission)) { try await explicit.value }
        #expect(prompts == 0)
        #expect(files.writes.count == 1)
        #expect(files.savedModes.isEmpty)
        #expect(document.isDirty)
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

    private func observeNextSaveSynchronization(_ document: EditorDocument) -> TestGate {
        let synchronized = TestGate()
        document.synchronizeEditor = { complete in
            complete(.success(()))
            // A synchronous acknowledgment does not suspend the MainActor save.
            // The test resumes only after it reaches the pending write's await.
            synchronized.open()
        }
        return synchronized
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

    private final class WriteCheck: Sendable {
        let started = TestGate(), release = TestGate()
        let failure: any Error
        init(failure: any Error = DocumentHardLinkConfirmationRequired(targetIdentity: "target")) {
            self.failure = failure
        }
        func wait(timeout: Duration) async throws {
            started.open()
            #expect(await release.waitUntilOpen(timeout: timeout), "Automatic hard-link check gate timed out")
            throw failure
        }
    }

    private final class Files: WorkspaceFileOperations, @unchecked Sendable {
        struct Write: Sendable {
            let text: String
            let baseline: String?
            let identity: String?
            let encoding: DocumentEncoding
        }
        private let failure: Error?
        private let updatesSharedContents: Bool
        private let authorizedFailure: Error?
        private let firstWriteCheck: WriteCheck?
        private let lock = NSLock()
        private var modes: [DocumentHardLinkSaveMode] = []
        private var recordedWrites: [Write] = []
        private var sharedText = "original"
        private var sharedIdentity = "bytes"
        var savedModes: [DocumentHardLinkSaveMode] { lock.withLock { modes } }
        var writes: [Write] { lock.withLock { recordedWrites } }
        init(failure: Error? = nil, updatesSharedContents: Bool = false, authorizedFailure: Error? = nil,
            firstWriteCheck: WriteCheck? = nil) {
            self.failure = failure
            self.updatesSharedContents = updatesSharedContents
            self.authorizedFailure = authorizedFailure
            self.firstWriteCheck = firstWriteCheck
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
            let isFirst = lock.withLock {
                recordedWrites.append(.init(text: text, baseline: expectedContent, identity: expectedIdentity, encoding: encoding))
                return recordedWrites.count == 1
            }
            if isFirst, let firstWriteCheck { try await firstWriteCheck.wait(timeout: .seconds(2)) }
            throw DocumentHardLinkConfirmationRequired(targetIdentity: "target")
        }
        func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding,
            expectedIdentity: String?, hardLinkAuthorization: DocumentHardLinkAuthorization) async throws -> EncodedDocumentWriteResult {
            #expect(hardLinkAuthorization.targetIdentity == "target")
            return try lock.withLock {
                recordedWrites.append(.init(text: text, baseline: expectedContent, identity: expectedIdentity, encoding: encoding))
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
