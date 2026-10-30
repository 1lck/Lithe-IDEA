import Foundation
import Testing
@testable import Lithe

@MainActor
struct PluginHostBrowserServiceTests {
    private func web(_ fixture: PluginHostFixture, _ address: String) -> PluginHostExternalOpenRequest {
        PluginHostExternalOpenRequest(context: fixture.context(), target: .webURL(address))
    }

    private func file(
        _ fixture: PluginHostFixture, _ relative: String, unsaved: PluginHostUnsavedPolicy = .openSavedFile
    ) -> PluginHostExternalOpenRequest {
        PluginHostExternalOpenRequest(
            context: fixture.context(), target: .workspaceFile(fixture.resource(relative)), unsaved: unsaved
        )
    }

    // MARK: Web addresses

    @Test func opensHTTPAndHTTPSAddressesAndLowercasesTheScheme() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }

        let secure = try await fixture.browser.openExternal(web(fixture, "https://example.com/docs?q=1#top"))
        let upper = try await fixture.browser.openExternal(web(fixture, "HTTP://example.com/a"))

        #expect(secure.content == .webPage)
        #expect(secure.openedURL.absoluteString == "https://example.com/docs?q=1#top")
        #expect(upper.openedURL.absoluteString == "http://example.com/a")
        #expect(fixture.opener.webURLs.map(\.absoluteString) == ["https://example.com/docs?q=1#top", "http://example.com/a"])
        #expect(fixture.opener.htmlFiles.isEmpty)
        // A web address never touches the window's documents.
        #expect(fixture.window.openCalls.isEmpty)
        #expect(fixture.window.flushedPaths.isEmpty)
    }

    @Test func refusesEverythingThatIsNotAPlainWebAddress() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let refused = [
            "", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>hi</b>",
            "ftp://example.com/a", "lithe-plugin://plugin/index.html", "mailto:someone@example.com",
            "vbscript:msgbox(1)", "about:blank", "example.com", "//example.com/a", "/relative/path",
            "https:///no-host", "https://", "http://user:secret@example.com/", "http://user@example.com/",
            "https://exa mple.com/", " https://example.com/", "https://example.com/\n", "https://example.com/\u{0}",
            "https://example.com/\u{85}", "https://example.com/" + String(repeating: "a", count: PluginHostBrowserService.maxURLBytes)
        ]

        for address in refused {
            await #expect(throws: PluginHostError.unsupportedURL, "address: \(address.debugDescription)") {
                try await fixture.browser.openExternal(web(fixture, address))
            }
        }
        #expect(fixture.opener.webURLs.isEmpty)
        #expect(fixture.opener.htmlFiles.isEmpty)
    }

    @Test func aLauncherFailureIsReportedAndACancellationPassesThrough() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")

        fixture.opener.failure = CocoaError(.fileNoSuchFile)
        await #expect(throws: PluginHostError.browserUnavailable) {
            try await fixture.browser.openExternal(web(fixture, "https://example.com/"))
        }
        await #expect(throws: PluginHostError.browserUnavailable) {
            try await fixture.browser.openExternal(file(fixture, "a.html"))
        }

        fixture.opener.failure = CancellationError()
        await #expect(throws: CancellationError.self) {
            try await fixture.browser.openExternal(web(fixture, "https://example.com/"))
        }
    }

    // MARK: Workspace files and unsaved edits

    @Test func openingASavedFileHandsTheBrowserTheFileOnDisk() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("site/index.html")
        fixture.window.openBuffers[fixture.path("site/index.html")] = false

        let result = try await fixture.browser.openExternal(file(fixture, "site/index.html"))

        #expect(result.content == .savedFile(hasUnsavedChanges: false))
        #expect(result.openedURL.path == fixture.path("site/index.html"))
        #expect(fixture.opener.htmlFiles.map(\.path) == [fixture.path("site/index.html")])
        #expect(fixture.opener.webURLs.isEmpty)
        // The browser reads the disk, so the editor is not asked to open or reload anything.
        #expect(fixture.window.openCalls.isEmpty)
        #expect(fixture.window.diskLoads.isEmpty)
    }

    @Test func aFileThatIsNotOpenHasNoUnsavedChanges() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")

        let result = try await fixture.browser.openExternal(file(fixture, "a.html", unsaved: .requireSaved))

        #expect(result.content == .savedFile(hasUnsavedChanges: false))
        #expect(fixture.opener.htmlFiles.count == 1)
    }

    @Test func aDirtyBufferIsFlaggedInTheResultWhenTheCallerAcceptsTheSavedFile() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.window.openBuffers[fixture.path("a.html")] = true

        let result = try await fixture.browser.openExternal(file(fixture, "a.html", unsaved: .openSavedFile))

        #expect(result.content == .savedFile(hasUnsavedChanges: true))
        #expect(fixture.opener.htmlFiles.map(\.path) == [fixture.path("a.html")])
        // The buffer itself is left as it was.
        #expect(fixture.window.openBuffers[fixture.path("a.html")] == true)
    }

    @Test func aDirtyBufferStopsTheLaunchWhenTheCallerRequiresASavedFile() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.window.openBuffers[fixture.path("a.html")] = true

        await #expect(throws: PluginHostError.unsavedChanges) {
            try await fixture.browser.openExternal(file(fixture, "a.html", unsaved: .requireSaved))
        }
        #expect(fixture.opener.htmlFiles.isEmpty)
    }

    @Test func inputTheEditorHasNotReportedYetCountsAsUnsaved() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        // The buffer looks clean until the editor reports what was just typed.
        fixture.window.openBuffers[fixture.path("a.html")] = false
        fixture.window.pendingEditorInput = [fixture.path("a.html")]

        await #expect(throws: PluginHostError.unsavedChanges) {
            try await fixture.browser.openExternal(file(fixture, "a.html", unsaved: .requireSaved))
        }
        #expect(fixture.window.flushedPaths == [fixture.path("a.html")])
        #expect(fixture.opener.htmlFiles.isEmpty)
    }

    @Test func onlyHTMLFilesOfTheWorkspaceMayBeLaunched() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("notes.md")
        fixture.addFile("run.sh")
        fixture.table.addFile("/fixture/outside/page.html")
        fixture.table.links[fixture.path("link/page.html")] = "/fixture/outside/page.html"

        for path in ["notes.md", "run.sh"] {
            await #expect(throws: PluginHostError.notHTMLDocument, "path: \(path)") {
                try await fixture.browser.openExternal(file(fixture, path))
            }
        }
        await #expect(throws: PluginHostError.outsideWorkspace) {
            try await fixture.browser.openExternal(file(fixture, "link/page.html"))
        }
        await #expect(throws: PluginHostError.invalidResourcePath) {
            try await fixture.browser.openExternal(file(fixture, "../outside/page.html"))
        }
        await #expect(throws: PluginHostError.resourceNotFound) {
            try await fixture.browser.openExternal(file(fixture, "missing.html"))
        }
        #expect(fixture.opener.htmlFiles.isEmpty)
    }

    // MARK: Window and workspace scope

    @Test func remoteWorkspacesAreRefusedForFilesAndAddresses() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.updateSnapshot(isRemote: true)

        await #expect(throws: PluginHostError.remoteWorkspaceUnsupported) {
            try await fixture.browser.openExternal(file(fixture, "a.html"))
        }
        await #expect(throws: PluginHostError.remoteWorkspaceUnsupported) {
            try await fixture.browser.openExternal(web(fixture, "https://example.com/"))
        }
        #expect(fixture.opener.htmlFiles.isEmpty)
        #expect(fixture.opener.webURLs.isEmpty)
    }

    @Test func aMissingWindowAndAReplacedWorkspaceAreRefused() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")

        await #expect(throws: PluginHostError.windowUnavailable) {
            try await fixture.browser.openExternal(PluginHostExternalOpenRequest(
                context: fixture.context(windowID: UUID()), target: .webURL("https://example.com/")
            ))
        }
        await #expect(throws: PluginHostError.workspaceChanged) {
            try await fixture.browser.openExternal(PluginHostExternalOpenRequest(
                context: fixture.context(generation: PluginHostFixture.defaultGeneration + 1),
                target: .workspaceFile(fixture.resource("a.html"))
            ))
        }
        #expect(fixture.opener.htmlFiles.isEmpty)
        #expect(fixture.opener.webURLs.isEmpty)
    }

    @Test func aWindowThatClosesWhileTheEditorReportsItsInputNeverLaunchesTheBrowser() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        fixture.addFile("a.html")
        fixture.window.openBuffers[fixture.path("a.html")] = false
        let directory = fixture.directory
        let windowID = fixture.windowID
        fixture.window.whileFlushing = { directory.windows[windowID] = nil }

        await #expect(throws: PluginHostError.windowUnavailable) {
            try await fixture.browser.openExternal(file(fixture, "a.html"))
        }
        #expect(fixture.opener.htmlFiles.isEmpty)
    }
}
