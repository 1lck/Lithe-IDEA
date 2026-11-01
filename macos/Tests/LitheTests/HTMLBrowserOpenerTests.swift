import Foundation
import Testing
@testable import Lithe

@MainActor
struct HTMLBrowserOpenerTests {
    @Test func htmlUsesBrowserAssociationInsteadOfFileAssociation() async throws {
        let file = URL(fileURLWithPath: "/fixture/中文 folder/page #1.HTML")
        let browser = URL(fileURLWithPath: "/fixture/Browser.app")
        var opened = false
        let opener = MacHTMLBrowserOpener(
            applicationForURL: { probe in
                #expect(probe.scheme == "https")
                #expect(!probe.isFileURL)
                return browser
            },
            openURLs: { urls, application in
                #expect(urls == [file])
                #expect(application == browser)
                opened = true
            },
            isRegularFile: { _ in true }
        )
        try await opener.open(file)
        #expect(opened)
    }

    @Test func missingBrowserAndLaunchFailuresAreReported() async {
        let file = URL(fileURLWithPath: "/fixture/page.html")
        let missing = MacHTMLBrowserOpener(
            applicationForURL: { _ in nil },
            openURLs: { _, _ in Issue.record("Must not fall back to the HTML association") },
            isRegularFile: { _ in true }
        )
        await #expect(throws: (any Error).self) { try await missing.open(file) }
        let failing = MacHTMLBrowserOpener(
            applicationForURL: { _ in URL(fileURLWithPath: "/fixture/Browser.app") },
            openURLs: { _, _ in throw CocoaError(.fileReadNoSuchFile) },
            isRegularFile: { _ in true }
        )
        await #expect(throws: CocoaError.self) { try await failing.open(file) }
    }

    @Test func rejectsNonHTMLRemoteAndMissingFiles() async {
        let opener = MacHTMLBrowserOpener(
            applicationForURL: { _ in
                Issue.record("Invalid input must not reach Launch Services")
                return nil
            },
            isRegularFile: { _ in false }
        )
        for url in [URL(fileURLWithPath: "/fixture/tool.sh"), URL(string: "https://example.invalid/page.html")!, URL(fileURLWithPath: "/fixture/missing.html")] {
            await #expect(throws: CocoaError.self) { try await opener.open(url) }
        }
    }

    // MARK: Web addresses

    @Test func webAddressesAreHandedToTheBrowserThatHandlesThem() async throws {
        let browser = URL(fileURLWithPath: "/fixture/Browser.app")
        for address in ["https://example.com/docs?q=1#top", "http://localhost:8080/", "HTTPS://Example.com/"] {
            let url = try #require(URL(string: address))
            var probed: URL?
            var opened: ([URL], URL)?
            let opener = MacHTMLBrowserOpener(
                applicationForURL: { probe in
                    probed = probe
                    return browser
                },
                openURLs: { urls, application in opened = (urls, application) }
            )

            try await opener.openWeb(url)

            #expect(probed == url)
            #expect(opened?.0 == [url])
            #expect(opened?.1 == browser)
        }
    }

    @Test func otherSchemesAndHostlessAddressesNeverReachLaunchServices() async {
        let opener = MacHTMLBrowserOpener(
            applicationForURL: { _ in
                Issue.record("Invalid input must not reach Launch Services")
                return nil
            },
            openURLs: { _, _ in Issue.record("Invalid input must not be opened") }
        )
        let refused = [
            "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/",
            "mailto:someone@example.com", "lithe-plugin://plugin/index.html", "x-apple.systempreferences:", "https:///no-host", "https://"
        ]

        for address in refused {
            guard let url = URL(string: address) else { continue }
            await #expect(throws: CocoaError.self, "address: \(address)") { try await opener.openWeb(url) }
        }
    }

    @Test func aMissingBrowserAndALaunchFailureAreReportedForWebAddresses() async throws {
        let url = try #require(URL(string: "https://example.com/"))
        let missing = MacHTMLBrowserOpener(
            applicationForURL: { _ in nil },
            openURLs: { _, _ in Issue.record("Must not open without a browser") }
        )
        await #expect(throws: CocoaError.self) { try await missing.openWeb(url) }
        let failing = MacHTMLBrowserOpener(
            applicationForURL: { _ in URL(fileURLWithPath: "/fixture/Browser.app") },
            openURLs: { _, _ in throw CocoaError(.fileReadNoSuchFile) }
        )
        await #expect(throws: CocoaError.self) { try await failing.openWeb(url) }
    }
}
