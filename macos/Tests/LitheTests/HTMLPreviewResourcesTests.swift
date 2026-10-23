import Foundation
import Testing
@testable import Lithe

/// A workspace on disk shaped like a small static site, removed when the test ends.
final class HTMLPreviewFixture {
    let root: URL
    let workspace: URL

    init(files: [String: String] = [:], binaryFiles: [String: Data] = [:]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-html-preview-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for (path, text) in files { try write(text, to: path) }
        for (path, data) in binaryFiles { try write(data, to: path) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// `path` is relative to the workspace; `../` reaches the fixture root.
    func url(_ path: String) -> URL {
        workspace.appendingPathComponent(path).standardizedFileURL
    }

    func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    /// For files that are not text, such as a WebAssembly module.
    func write(_ data: Data, to path: String) throws {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func scope(document: String) -> HTMLPreviewScope {
        HTMLPreviewScope(documentURL: url(document), workspaceURL: workspace)
    }

    /// The smallest useful WebAssembly module: it exports `add(i32, i32) -> i32`.
    static let addModule = Data([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic, version 1
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type section: (i32, i32) -> i32
        0x03, 0x02, 0x01, 0x00, // function section: one function of that type
        0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export section: "add"
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b // code: local.get 0, local.get 1, i32.add
    ])
}

struct HTMLPreviewResourcesTests {
    private func request(_ path: String, method: String = "GET", headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: "lithe-html://preview" + path)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func respond(
        _ request: URLRequest,
        fixture: HTMLPreviewFixture,
        document: String = "site/page.html",
        html: String = "<p>buffer</p>"
    ) -> HTMLPreviewResponse {
        HTMLPreviewResponder.respond(to: request, scope: fixture.scope(document: document), html: html)
    }

    private func text(_ response: HTMLPreviewResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    @Test func rootIsTheWorkspaceWhenTheDocumentIsInsideIt() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk"])
        let scope = fixture.scope(document: "site/page.html")
        #expect(scope.rootURL == fixture.workspace)
        #expect(HTMLPreviewURL.url(forFile: scope.documentURL, in: scope)?.absoluteString == "lithe-html://preview/site/page.html")
    }

    @Test func rootIsTheDocumentDirectoryWhenTheDocumentIsOutsideTheWorkspace() throws {
        let fixture = try HTMLPreviewFixture(files: ["page.html": "disk"])
        try fixture.write("elsewhere", to: "../loose/page.html")
        let scope = HTMLPreviewScope(documentURL: fixture.url("../loose/page.html"), workspaceURL: fixture.workspace)
        #expect(scope.rootURL == fixture.url("../loose"))
    }

    @Test func aSiblingDirectorySharingAPrefixIsNotInsideTheRoot() throws {
        let fixture = try HTMLPreviewFixture()
        try fixture.write("x", to: "../workspace-other/page.html")
        let scope = HTMLPreviewScope(documentURL: fixture.url("../workspace-other/page.html"), workspaceURL: fixture.workspace)
        #expect(scope.rootURL == fixture.url("../workspace-other"))
    }

    @Test func servesTheEditorBufferInsteadOfTheFileOnDisk() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk"])
        let response = respond(request("/site/page.html"), fixture: fixture, html: "<p>unsaved</p>")
        #expect(response.statusCode == 200)
        #expect(text(response) == "<p>unsaved</p>")
        #expect(response.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(response.headers["Cache-Control"] == "no-store")
    }

    @Test func servesRootRelativeAndSiblingFilesWithWebMIMETypes() throws {
        let fixture = try HTMLPreviewFixture(files: [
            "site/page.html": "disk",
            "assets/app.js": "export const a = 1",
            "site/style.css": "body{}",
            "data/info.json": "{}"
        ])
        let script = respond(request("/assets/app.js"), fixture: fixture)
        #expect(script.statusCode == 200)
        #expect(script.headers["Content-Type"] == "text/javascript")
        #expect(text(script) == "export const a = 1")
        #expect(respond(request("/site/style.css"), fixture: fixture).headers["Content-Type"] == "text/css")
        #expect(respond(request("/data/info.json"), fixture: fixture).headers["Content-Type"] == "application/json")
    }

    @Test func servesWebAssemblyModulesByteForByteWithTheirMIMEType() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk"], binaryFiles: ["assets/add.wasm": HTMLPreviewFixture.addModule])
        let response = respond(request("/assets/add.wasm"), fixture: fixture)
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "application/wasm")
        #expect(response.body == HTMLPreviewFixture.addModule)
    }

    @Test func servesTheIndexFileForADirectory() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk", "docs/index.html": "<p>index</p>"])
        #expect(text(respond(request("/docs/"), fixture: fixture)) == "<p>index</p>")
        #expect(respond(request("/empty/"), fixture: fixture).statusCode == 404)
    }

    @Test func missingFilesAreNotFound() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk"])
        #expect(respond(request("/nope.js"), fixture: fixture).statusCode == 404)
    }

    @Test func refusesHiddenEntriesAndKeyMaterial() throws {
        let fixture = try HTMLPreviewFixture(files: [
            "site/page.html": "disk",
            ".env": "TOKEN=secret",
            ".git/config": "[core]",
            "certs/server.pem": "-----BEGIN",
            "certs/server.KEY": "-----BEGIN",
            "keep/ok.txt": "ok"
        ])
        #expect(respond(request("/.env"), fixture: fixture).statusCode == 403)
        #expect(respond(request("/.git/config"), fixture: fixture).statusCode == 403)
        #expect(respond(request("/certs/server.pem"), fixture: fixture).statusCode == 403)
        #expect(respond(request("/certs/server.KEY"), fixture: fixture).statusCode == 403)
        #expect(respond(request("/keep/ok.txt"), fixture: fixture).statusCode == 200)
    }

    @Test func aDocumentInsideAHiddenDirectoryIsStillServed() throws {
        let fixture = try HTMLPreviewFixture(files: [".docs/page.html": "disk"])
        let response = respond(request("/.docs/page.html"), fixture: fixture, document: ".docs/page.html", html: "<p>b</p>")
        #expect(response.statusCode == 200)
    }

    @Test func parentTraversalAndSymbolicLinksCannotLeaveTheRoot() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk"])
        try fixture.write("outside", to: "../secret.txt")
        try FileManager.default.createSymbolicLink(
            at: fixture.url("link.txt"),
            withDestinationURL: fixture.url("../secret.txt")
        )
        #expect(respond(request("/../secret.txt"), fixture: fixture).statusCode == 404)
        #expect(respond(request("/site/%2e%2e/%2e%2e/secret.txt"), fixture: fixture).statusCode == 404)
        #expect(respond(request("/link.txt"), fixture: fixture).statusCode == 404)
    }

    @Test func onlyReadMethodsAreAllowed() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk", "a.txt": "abc"])
        let post = respond(request("/a.txt", method: "POST"), fixture: fixture)
        #expect(post.statusCode == 405)
        #expect(post.headers["Allow"] == "GET, HEAD")
        let head = respond(request("/a.txt", method: "HEAD"), fixture: fixture)
        #expect(head.statusCode == 200)
        #expect(head.body.isEmpty)
        #expect(head.headers["Content-Length"] == "3")
    }

    @Test func requestsFromOutsideThePreviewAreRefused() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk", "a.txt": "abc"])
        var remoteMain = request("/a.txt")
        remoteMain.mainDocumentURL = URL(string: "https://example.com/")
        #expect(respond(remoteMain, fixture: fixture).statusCode == 403)
        #expect(respond(request("/a.txt", headers: ["Referer": "https://example.com/x"]), fixture: fixture).statusCode == 403)

        var local = request("/a.txt", headers: ["Referer": "lithe-html://preview/site/page.html"])
        local.mainDocumentURL = URL(string: "lithe-html://preview/site/page.html")
        #expect(respond(local, fixture: fixture).statusCode == 200)
    }

    @Test func rangeRequestsReturnPartialContent() throws {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "disk", "clip.bin": "0123456789"])
        let partial = respond(request("/clip.bin", headers: ["Range": "bytes=2-4"]), fixture: fixture)
        #expect(partial.statusCode == 206)
        #expect(text(partial) == "234")
        #expect(partial.headers["Content-Range"] == "bytes 2-4/10")
        #expect(partial.headers["Content-Length"] == "3")

        let suffix = respond(request("/clip.bin", headers: ["Range": "bytes=-3"]), fixture: fixture)
        #expect(text(suffix) == "789")

        let beyond = respond(request("/clip.bin", headers: ["Range": "bytes=50-"]), fixture: fixture)
        #expect(beyond.statusCode == 416)
        #expect(beyond.headers["Content-Range"] == "bytes */10")
    }

    @Test func byteRangeParsingIgnoresMalformedHeaders() {
        #expect(HTMLPreviewResponder.ByteRange.parse(nil, length: 10) == .full)
        #expect(HTMLPreviewResponder.ByteRange.parse("items=1-2", length: 10) == .full)
        #expect(HTMLPreviewResponder.ByteRange.parse("bytes=1-2,4-5", length: 10) == .full)
        #expect(HTMLPreviewResponder.ByteRange.parse("bytes=5-2", length: 10) == .full)
        #expect(HTMLPreviewResponder.ByteRange.parse("bytes=0-99", length: 10) == .satisfiable(0..<10))
    }

    @Test func fileURLsRoundTripThroughPreviewURLs() throws {
        let fixture = try HTMLPreviewFixture(files: ["dir with space/页面 #1.html": "x"])
        let scope = fixture.scope(document: "dir with space/页面 #1.html")
        let url = try #require(HTMLPreviewURL.url(forFile: scope.documentURL, in: scope))
        #expect(!url.absoluteString.contains(" "))
        #expect(url.fragment == nil)
        #expect(HTMLPreviewURL.fileURL(for: url, in: scope) == scope.documentURL)
    }

    @Test func folderURLsEndWithASlashSoRelativeLinksResolveInsideThem() throws {
        let fixture = try HTMLPreviewFixture(files: ["docs/index.html": "x", "page.html": "x"])
        let scope = fixture.scope(document: "page.html")
        #expect(HTMLPreviewURL.url(forFile: fixture.url("docs"), in: scope)?.absoluteString == "lithe-html://preview/docs/")
        #expect(HTMLPreviewURL.url(forFile: fixture.workspace, in: scope)?.absoluteString == "lithe-html://preview/")
        #expect(HTMLPreviewURL.url(forFile: fixture.url("docs/index.html"), in: scope)?.absoluteString == "lithe-html://preview/docs/index.html")
    }

    @Test func aFolderAddressWithoutASlashIsRedirectedToTheOneWithIt() throws {
        let fixture = try HTMLPreviewFixture(files: ["docs/index.html": "x", "docs/a b/index.html": "x", "page.html": "x"])
        let scope = fixture.scope(document: "page.html")
        func redirect(_ address: String) -> String? {
            HTMLPreviewURL.folderRedirect(for: URL(string: address)!, in: scope)?.absoluteString
        }

        #expect(redirect("lithe-html://preview/docs") == "lithe-html://preview/docs/")
        // The query and fragment ride along, as with a server's redirect.
        #expect(redirect("lithe-html://preview/docs?x=1#top") == "lithe-html://preview/docs/?x=1#top")
        #expect(redirect("lithe-html://preview/docs/a%20b") == "lithe-html://preview/docs/a%20b/")
        #expect(redirect("lithe-html://preview") == "lithe-html://preview/")

        // Already slashed, files, missing entries and other hosts are left alone.
        #expect(redirect("lithe-html://preview/docs/") == nil)
        #expect(redirect("lithe-html://preview/docs/index.html") == nil)
        #expect(redirect("lithe-html://preview/missing") == nil)
        #expect(redirect("https://example.com/docs") == nil)
        #expect(redirect("lithe-html://preview/../docs") == nil)
    }

    @Test func savingAFileCopiesItAndReplacesAnExistingOne() throws {
        let fixture = try HTMLPreviewFixture(files: ["data.txt": "source", "taken.txt": "old"])

        try HTMLPreviewFileSaver.save(fixture.url("data.txt"), bufferText: nil, to: fixture.url("copy.txt"))
        try HTMLPreviewFileSaver.save(fixture.url("data.txt"), bufferText: nil, to: fixture.url("taken.txt"))

        #expect(try String(contentsOf: fixture.url("copy.txt"), encoding: .utf8) == "source")
        #expect(try String(contentsOf: fixture.url("taken.txt"), encoding: .utf8) == "source")
    }

    @Test func savingAFileOverItselfKeepsIt() throws {
        let fixture = try HTMLPreviewFixture(files: ["data.txt": "source"])
        try FileManager.default.createSymbolicLink(at: fixture.url("alias.txt"), withDestinationURL: fixture.url("data.txt"))

        try HTMLPreviewFileSaver.save(fixture.url("data.txt"), bufferText: nil, to: fixture.url("data.txt"))
        try HTMLPreviewFileSaver.save(fixture.url("data.txt"), bufferText: nil, to: fixture.url("alias.txt"))

        #expect(try String(contentsOf: fixture.url("data.txt"), encoding: .utf8) == "source")
    }

    @Test func savingThePreviewedDocumentWritesTheEditorText() throws {
        let fixture = try HTMLPreviewFixture(files: ["page.html": "disk"])

        try HTMLPreviewFileSaver.save(fixture.url("page.html"), bufferText: "unsaved edit", to: fixture.url("saved.html"))

        #expect(try String(contentsOf: fixture.url("saved.html"), encoding: .utf8) == "unsaved edit")
    }
}
