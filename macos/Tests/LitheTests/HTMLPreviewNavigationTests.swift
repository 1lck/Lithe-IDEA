import Foundation
import Testing
import WebKit
@testable import Lithe

struct HTMLPreviewNavigationTests {
    private func decide(
        _ url: String,
        type: WKNavigationType = .linkActivated,
        target: HTMLPreviewNavigationRequest.Target = .mainFrame,
        download: Bool = false
    ) -> HTMLPreviewNavigationDecision {
        HTMLPreviewNavigationPolicy.decide(HTMLPreviewNavigationRequest(
            url: URL(string: url)!,
            type: type,
            target: target,
            shouldDownload: download
        ))
    }

    @Test func linksInsideThePreviewAndOnTheWebAreFollowed() {
        #expect(decide("lithe-html://preview/other.html") == .allow)
        #expect(decide("lithe-html://preview/page.html#section") == .allow)
        #expect(decide("https://example.com/") == .allow)
        #expect(decide("http://localhost:3000/") == .allow)
        #expect(decide("about:blank", target: .subframe) == .allow)
    }

    @Test func newWindowRequestsLoadInThePreviewTab() {
        let url = URL(string: "https://example.com/docs")!
        #expect(decide("https://example.com/docs", target: .newWindow) == .loadInPlace(url))
        #expect(decide("lithe-html://preview/b.html", target: .newWindow) == .loadInPlace(URL(string: "lithe-html://preview/b.html")!))
    }

    @Test func mailAndPhoneLinksLeaveThePreviewOnlyWhenClicked() {
        let mail = URL(string: "mailto:team@example.com")!
        #expect(decide("mailto:team@example.com") == .openExternally(mail))
        #expect(decide("mailto:team@example.com", type: .other) == .cancel)
        #expect(decide("tel:+10000000", type: .other) == .cancel)
    }

    @Test func localFilesAndUnknownSchemesAreNeverLoaded() {
        #expect(decide("file:///etc/passwd") == .cancel)
        #expect(decide("file:///etc/passwd", target: .subframe) == .cancel)
        #expect(decide("x-apple.systempreferences:com.apple.preference") == .cancel)
        #expect(decide("ssh://example.com") == .cancel)
    }

    @Test func dataAndBlobDocumentsAreOnlyAllowedInsideFrames() {
        #expect(decide("data:text/html,hi", target: .mainFrame) == .cancel)
        #expect(decide("data:text/html,hi", target: .subframe) == .allow)
        #expect(decide("blob:https://example.com/id", target: .mainFrame) == .cancel)
        #expect(decide("blob:https://example.com/id", target: .subframe) == .allow)
    }

    @Test func downloadRequestsAreDownloaded() {
        #expect(decide("https://example.com/file.zip", download: true) == .download)
        #expect(decide("lithe-html://preview/file.zip", download: true) == .download)
    }
}

struct HTMLPreviewAddressTests {
    private func fixture() throws -> (HTMLPreviewFixture, HTMLPreviewScope) {
        let fixture = try HTMLPreviewFixture(files: ["site/page.html": "x", "site/other.html": "y"])
        return (fixture, fixture.scope(document: "site/page.html"))
    }

    @Test func localPagesAreShownAsTheirFileURL() throws {
        let (fixture, scope) = try fixture()
        let internalURL = try #require(HTMLPreviewURL.url(forFile: fixture.url("site/other.html"), in: scope))
        #expect(HTMLPreviewAddress.display(for: internalURL, in: scope) == fixture.url("site/other.html").absoluteString)

        let withFragment = try #require(URL(string: internalURL.absoluteString + "?a=1#top"))
        #expect(HTMLPreviewAddress.display(for: withFragment, in: scope).hasSuffix("other.html?a=1#top"))
    }

    @Test func remoteAndEmptyAddressesAreShownVerbatim() throws {
        let (_, scope) = try fixture()
        #expect(HTMLPreviewAddress.display(for: URL(string: "https://example.com/a?b=1"), in: scope) == "https://example.com/a?b=1")
        #expect(HTMLPreviewAddress.display(for: URL(string: "about:blank"), in: scope) == "")
        #expect(HTMLPreviewAddress.display(for: nil, in: scope) == "")
    }

    @Test func typedPathsAndFileURLsResolveToPreviewPages() throws {
        let (fixture, scope) = try fixture()
        let expected = try #require(HTMLPreviewURL.url(forFile: fixture.url("site/other.html"), in: scope))
        #expect(HTMLPreviewAddress.resolve(fixture.url("site/other.html").path, in: scope) == expected)
        #expect(HTMLPreviewAddress.resolve(fixture.url("site/other.html").absoluteString, in: scope) == expected)
        #expect(HTMLPreviewAddress.resolve("  \(fixture.url("site/other.html").path)\n", in: scope) == expected)

        let withFragment = HTMLPreviewAddress.resolve(fixture.url("site/other.html").absoluteString + "#part", in: scope)
        #expect(withFragment?.fragment == "part")
    }

    @Test func filesOutsideTheServedRootCannotBeOpened() throws {
        let (_, scope) = try fixture()
        #expect(HTMLPreviewAddress.resolve("/etc/hosts", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("file:///etc/hosts", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("~/Documents/a.html", in: scope) == nil)
    }

    @Test func webAddressesGetASchemeWhenOmitted() throws {
        let (_, scope) = try fixture()
        #expect(HTMLPreviewAddress.resolve("https://example.com/a", in: scope)?.absoluteString == "https://example.com/a")
        #expect(HTMLPreviewAddress.resolve("example.com/docs", in: scope)?.absoluteString == "https://example.com/docs")
        #expect(HTMLPreviewAddress.resolve("localhost:3000", in: scope)?.absoluteString == "http://localhost:3000")
        #expect(HTMLPreviewAddress.resolve("127.0.0.1:8080/x", in: scope)?.absoluteString == "http://127.0.0.1:8080/x")
    }

    @Test func textThatIsNotAnAddressIsRejected() throws {
        let (_, scope) = try fixture()
        #expect(HTMLPreviewAddress.resolve("", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("   ", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("hello", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("hello world.com", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("javascript:alert(1)", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("ftp://example.com/x", in: scope) == nil)
        #expect(HTMLPreviewAddress.resolve("https://", in: scope) == nil)
    }
}
