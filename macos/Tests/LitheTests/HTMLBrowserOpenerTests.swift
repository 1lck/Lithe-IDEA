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
            }
        )
        try await opener.open(file)
        #expect(opened)
    }

    @Test func missingBrowserAndLaunchFailuresAreReported() async {
        let file = URL(fileURLWithPath: "/fixture/page.html")
        let missing = MacHTMLBrowserOpener(
            applicationForURL: { _ in nil },
            openURLs: { _, _ in Issue.record("Must not fall back to the HTML association") }
        )
        await #expect(throws: (any Error).self) { try await missing.open(file) }
        let failing = MacHTMLBrowserOpener(
            applicationForURL: { _ in URL(fileURLWithPath: "/fixture/Browser.app") },
            openURLs: { _, _ in throw CocoaError(.fileReadNoSuchFile) }
        )
        await #expect(throws: CocoaError.self) { try await failing.open(file) }
    }

    @Test func rejectsNonHTMLAndRemoteURLs() async {
        let opener = MacHTMLBrowserOpener(
            applicationForURL: { _ in
                Issue.record("Invalid input must not reach Launch Services")
                return nil
            }
        )
        for url in [URL(fileURLWithPath: "/fixture/tool.sh"), URL(string: "https://example.invalid/page.html")!] {
            await #expect(throws: CocoaError.self) { try await opener.open(url) }
        }
    }
}
