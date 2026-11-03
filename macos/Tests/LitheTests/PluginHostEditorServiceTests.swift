import Foundation
import Testing
@testable import Lithe

@MainActor
struct PluginHostEditorServiceTests {
    // MARK: Opening and the document owner

    @Test func opensAFileThatIsNotOpenYetFromDiskExactlyOnce() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("src/index.html")

        let result = try await fixture.editor.open(fixture.openRequest("src/index.html"))

        #expect(!result.wasAlreadyOpen)
        #expect(result.document.isOpen)
        #expect(result.document.isActive)
        #expect(!result.document.hasUnsavedChanges)
        #expect(result.appliedSelection == PluginHostAppliedSelection.none)
        #expect(fixture.window.diskLoads == [fixture.path("src/index.html")])
    }

    @Test func anOpenDirtyBufferIsKeptAndNeverReloadedFromDisk() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("page.html")
        fixture.window.openBuffers[fixture.path("page.html")] = true
        fixture.window.foregroundPath = fixture.path("page.html")

        let result = try await fixture.editor.open(fixture.openRequest("page.html"))

        #expect(result.wasAlreadyOpen)
        #expect(result.document.hasUnsavedChanges)
        #expect(fixture.window.diskLoads.isEmpty)
        #expect(fixture.window.openBuffers[fixture.path("page.html")] == true)
    }

    // MARK: Foreground tab

    @Test func selectBringsABackgroundTabToTheFrontAndKeepsItsUnsavedEdits() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.addFile("b.html")
        fixture.window.openBuffers = [fixture.path("a.html"): true, fixture.path("b.html"): false]
        fixture.window.foregroundPath = fixture.path("b.html")
        // Before the call a.html is open but in the background, where the
        // editor slice would refuse to read its selection or edit it.
        let before = await fixture.window.hostDocumentState(at: fixture.url("a.html"), flushingEditor: false)
        #expect(before?.isOpen == true)
        #expect(before?.isActive == false)

        let result = try await fixture.editor.open(fixture.openRequest("a.html"))

        #expect(result.wasAlreadyOpen)
        #expect(result.document.isActive)
        #expect(fixture.window.foregroundPath == fixture.path("a.html"))
        #expect(result.document.hasUnsavedChanges)
        #expect(fixture.window.diskLoads.isEmpty)
        // The tab that was in front is still open, now behind.
        #expect(fixture.window.openBuffers[fixture.path("b.html")] == false)
        let behind = await fixture.window.hostDocumentState(at: fixture.url("b.html"), flushingEditor: false)
        #expect(behind?.isActive == false)
    }

    @Test func selectingAClosedFileMakesItTheForegroundTab() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.addFile("b.html")
        fixture.window.openBuffers = [fixture.path("a.html"): false]
        fixture.window.foregroundPath = fixture.path("a.html")

        let result = try await fixture.editor.open(fixture.openRequest("b.html"))

        #expect(!result.wasAlreadyOpen)
        #expect(result.document.isActive)
        #expect(fixture.window.foregroundPath == fixture.path("b.html"))
    }

    @Test func backgroundActivationLeavesTheForegroundTabAndCaretAlone() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.addFile("b.html")
        fixture.window.openBuffers = [fixture.path("a.html"): false]
        fixture.window.foregroundPath = fixture.path("a.html")
        let range = PluginHostTextRange(start: .init(line: 3, column: 2), end: .init(line: 3, column: 9))

        let result = try await fixture.editor.open(fixture.openRequest("b.html", range: range, activation: .background))

        #expect(result.document.isOpen)
        #expect(!result.document.isActive)
        #expect(fixture.window.foregroundPath == fixture.path("a.html"))
        #expect(fixture.window.caretPlacements.isEmpty)
        #expect(result.appliedSelection == PluginHostAppliedSelection.none)
    }

    @Test func aBackgroundWindowIsServedButNeverRaised() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.updateSnapshot(isForeground: false)

        let result = try await fixture.editor.open(fixture.openRequest("a.html"))

        // The file became the foreground tab of its own window, and the
        // result says the window itself is not the one the user is in.
        #expect(result.document.isActive)
        #expect(!result.windowIsForeground)
        #expect(fixture.window.snapshot?.isForeground == false)
    }

    @Test func aCallForAnotherWindowNeverTouchesTheWindowInFront() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        let other = fixture.addWindow(isForeground: false)
        let request = PluginHostEditorOpenRequest(
            context: fixture.context(windowID: other.id), resource: fixture.resource("a.html")
        )

        _ = try await fixture.editor.open(request)

        #expect(other.window.openCalls.map(\.path) == [fixture.path("a.html")])
        #expect(fixture.window.openCalls.isEmpty)
    }

    // MARK: Location

    @Test func selectingWithARangePlacesTheCaretAtItsStart() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        let start = PluginHostPosition(line: 12, column: 5)
        let range = PluginHostTextRange(start: start, end: .init(line: 14, column: 1))

        let result = try await fixture.editor.open(fixture.openRequest("a.html", range: range))

        #expect(result.appliedSelection == .caret(start))
        #expect(fixture.window.caretPlacements == [
            .init(path: fixture.path("a.html"), position: start)
        ])
    }

    @Test func invalidRangesAreRefusedBeforeAnythingOpens() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        let ranges = [
            PluginHostTextRange(start: .init(line: 0, column: 1), end: .init(line: 1, column: 1)),
            PluginHostTextRange(start: .init(line: 1, column: 0), end: .init(line: 1, column: 1)),
            PluginHostTextRange(start: .init(line: -3, column: 1), end: .init(line: 1, column: 1)),
            PluginHostTextRange(start: .init(line: 5, column: 4), end: .init(line: 5, column: 3)),
            PluginHostTextRange(start: .init(line: 5, column: 1), end: .init(line: 4, column: 9)),
            PluginHostTextRange(start: .init(line: PluginHostPositionValidation.maxLine + 1, column: 1), end: .init(line: PluginHostPositionValidation.maxLine + 1, column: 1))
        ]

        for range in ranges {
            await #expect(throws: PluginHostError.invalidPosition) {
                try await fixture.editor.open(fixture.openRequest("a.html", range: range))
            }
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    @Test func aReplaceablePreviewTabIsRefusedInsteadOfOpenedAsARegularTab() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")

        await #expect(throws: PluginHostError.unsupportedOption) {
            try await fixture.editor.open(fixture.openRequest("a.html", tab: .preview))
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    // MARK: Reveal

    @Test func revealNeverLoadsAFileThatIsNotOpen() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")

        await #expect(throws: PluginHostError.documentNotOpen) {
            try await fixture.editor.reveal(fixture.openRequest("a.html"))
        }
        #expect(fixture.window.openCalls.isEmpty)
        #expect(fixture.window.diskLoads.isEmpty)
    }

    @Test func revealBringsAnOpenBackgroundFileForwardAndPlacesTheCaret() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.addFile("b.html")
        fixture.window.openBuffers = [fixture.path("a.html"): true, fixture.path("b.html"): false]
        fixture.window.foregroundPath = fixture.path("b.html")
        let position = PluginHostPosition(line: 2, column: 3)
        let range = PluginHostTextRange(start: position, end: position)

        let result = try await fixture.editor.reveal(fixture.openRequest("a.html", range: range))

        #expect(result.wasAlreadyOpen)
        #expect(result.document.isActive)
        #expect(result.document.hasUnsavedChanges)
        #expect(result.appliedSelection == .caret(position))
        #expect(fixture.window.diskLoads.isEmpty)
    }

    @Test func aFileTheOwnerCannotOpenAsTextIsReported() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("photo.bin")
        fixture.window.unopenablePaths = [fixture.path("photo.bin")]

        await #expect(throws: PluginHostError.openFailed) {
            try await fixture.editor.open(fixture.openRequest("photo.bin"))
        }
    }

    // MARK: Resources

    @Test func pathsThatLeaveTheWorkspaceOrAreMalformedAreRefused() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        let malformed = [
            "", "/etc/passwd", "../secret.txt", "a/../../secret.txt", "a/./b.html", "a//b.html",
            "a/", "a\\b.html", "a\u{0}.html", "a\n.html", String(repeating: "x", count: PluginHostResourceResolver.maxPathBytes + 1)
        ]

        for path in malformed {
            await #expect(throws: PluginHostError.invalidResourcePath, "path: \(path.debugDescription)") {
                try await fixture.editor.open(fixture.openRequest(path))
            }
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    @Test func anUnknownRootAndASymbolicLinkOutOfTheWorkspaceAreRefused() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.table.addFile("/fixture/outside/secret.txt")
        fixture.table.links[fixture.path("link/secret.txt")] = "/fixture/outside/secret.txt"
        // A sibling folder that merely starts with the workspace's name.
        fixture.table.addFile("/fixture/workspace-evil/x.html")
        fixture.table.links[fixture.path("evil/x.html")] = "/fixture/workspace-evil/x.html"

        await #expect(throws: PluginHostError.unknownRoot) {
            try await fixture.editor.open(PluginHostEditorOpenRequest(
                context: fixture.context(), resource: fixture.resource("a.html", root: "other")
            ))
        }
        for path in ["link/secret.txt", "evil/x.html"] {
            await #expect(throws: PluginHostError.outsideWorkspace, "path: \(path)") {
                try await fixture.editor.open(fixture.openRequest(path))
            }
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    @Test func missingFilesAndFoldersAreRefused() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.table.addDirectory(fixture.path("folder"))

        await #expect(throws: PluginHostError.resourceNotFound) {
            try await fixture.editor.open(fixture.openRequest("missing.html"))
        }
        await #expect(throws: PluginHostError.notRegularFile) {
            try await fixture.editor.open(fixture.openRequest("folder"))
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    // MARK: Window and workspace scope

    @Test func remoteWorkspacesAreRefusedBeforeAnythingElseIsChecked() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.updateSnapshot(isRemote: true)

        // The path does not even exist: the remote refusal comes first, so a
        // plugin learns nothing about the other machine's files.
        await #expect(throws: PluginHostError.remoteWorkspaceUnsupported) {
            try await fixture.editor.open(fixture.openRequest("missing.html"))
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    @Test func aClosedWindowAndAReplacedWorkspaceAreRefused() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")

        await #expect(throws: PluginHostError.windowUnavailable) {
            try await fixture.editor.open(PluginHostEditorOpenRequest(
                context: fixture.context(windowID: UUID()), resource: fixture.resource("a.html")
            ))
        }
        await #expect(throws: PluginHostError.workspaceChanged) {
            try await fixture.editor.open(PluginHostEditorOpenRequest(
                context: fixture.context(generation: PluginHostFixture.defaultGeneration + 1),
                resource: fixture.resource("a.html")
            ))
        }
        // Without a workspace the window has no snapshot at all.
        fixture.window.snapshot = nil
        await #expect(throws: PluginHostError.windowUnavailable) {
            try await fixture.editor.open(fixture.openRequest("a.html"))
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    @Test func aWindowThatClosesWhileTheFileLoadsGetsNoCaretAndNoResult() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        let directory = fixture.directory
        let windowID = fixture.windowID
        fixture.window.whileLoading = { directory.windows[windowID] = nil }
        let range = PluginHostTextRange(start: .init(line: 1, column: 1), end: .init(line: 1, column: 2))

        await #expect(throws: PluginHostError.windowUnavailable) {
            try await fixture.editor.open(fixture.openRequest("a.html", range: range))
        }
        #expect(fixture.window.caretPlacements.isEmpty)
    }

    @Test func aWorkspaceReplacedWhileTheFileLoadsGetsNoCaretAndNoResult() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.window.whileLoading = { [fixture] in
            fixture.updateSnapshot(generation: PluginHostFixture.defaultGeneration + 1)
        }
        let range = PluginHostTextRange(start: .init(line: 1, column: 1), end: .init(line: 1, column: 2))

        await #expect(throws: PluginHostError.workspaceChanged) {
            try await fixture.editor.open(fixture.openRequest("a.html", range: range))
        }
        #expect(fixture.window.caretPlacements.isEmpty)
    }
}

@MainActor
struct PluginHostPreviewServiceTests {
    @Test func opensTheHTMLFileInItsEditorTabWithTheLiveBuffer() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("site/index.html")
        fixture.addFile("other.html")
        fixture.window.openBuffers = [fixture.path("site/index.html"): true, fixture.path("other.html"): false]
        fixture.window.foregroundPath = fixture.path("other.html")

        let result = try await fixture.preview.openHTML(PluginHostPreviewOpenRequest(
            context: fixture.context(), resource: fixture.resource("site/index.html")
        ))

        #expect(result.usesLiveBuffer)
        #expect(result.presentation == .editorAndPreview)
        #expect(result.editor.document.isActive)
        // The preview shows the buffer, so the unsaved edits stay in it.
        #expect(result.editor.document.hasUnsavedChanges)
        #expect(fixture.window.diskLoads.isEmpty)
        #expect(fixture.window.foregroundPath == fixture.path("site/index.html"))
    }

    @Test func acceptsEitherHTMLExtensionInAnyCase() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.HTML")
        fixture.addFile("b.htm")

        for path in ["a.HTML", "b.htm"] {
            let result = try await fixture.preview.openHTML(PluginHostPreviewOpenRequest(
                context: fixture.context(), resource: fixture.resource(path)
            ))
            #expect(result.editor.document.isActive)
        }
    }

    @Test func refusesOtherFilesBeforeTouchingTheWindow() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("notes.md")
        fixture.addFile("a.html")

        await #expect(throws: PluginHostError.notHTMLDocument) {
            try await fixture.preview.openHTML(PluginHostPreviewOpenRequest(
                context: fixture.context(), resource: fixture.resource("notes.md")
            ))
        }
        #expect(fixture.window.openCalls.isEmpty)
    }

    @Test func staysInsideTheWorkspaceAndTheNamedWindow() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.table.addFile("/fixture/outside/page.html")
        fixture.table.links[fixture.path("link/page.html")] = "/fixture/outside/page.html"

        await #expect(throws: PluginHostError.outsideWorkspace) {
            try await fixture.preview.openHTML(PluginHostPreviewOpenRequest(
                context: fixture.context(), resource: fixture.resource("link/page.html")
            ))
        }
        await #expect(throws: PluginHostError.windowUnavailable) {
            try await fixture.preview.openHTML(PluginHostPreviewOpenRequest(
                context: fixture.context(windowID: UUID()), resource: fixture.resource("link/page.html")
            ))
        }
        #expect(fixture.window.openCalls.isEmpty)
    }
}
