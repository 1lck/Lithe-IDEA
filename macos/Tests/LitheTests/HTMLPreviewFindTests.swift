import AppKit
import Testing
import WebKit
@testable import Lithe

struct HTMLPreviewFindShortcutTests {
    @Test func commandShortcutsMatchBrowsers() {
        #expect(HTMLPreviewFind.command(forKey: "f", modifiers: [.command]) == .show)
        #expect(HTMLPreviewFind.command(forKey: "g", modifiers: [.command]) == .next)
        #expect(HTMLPreviewFind.command(forKey: "G", modifiers: [.command, .shift]) == .previous)
        #expect(HTMLPreviewFind.command(forKey: "g", modifiers: [.command, .shift]) == .previous)
        // Caps Lock upper-cases the letter without changing the shortcut.
        #expect(HTMLPreviewFind.command(forKey: "F", modifiers: [.command, .capsLock]) == .show)
    }

    @Test func otherKeyCombinationsAreLeftToTheirOwners() {
        #expect(HTMLPreviewFind.command(forKey: "f", modifiers: []) == nil)
        #expect(HTMLPreviewFind.command(forKey: "f", modifiers: [.command, .shift]) == nil)
        #expect(HTMLPreviewFind.command(forKey: "f", modifiers: [.command, .option]) == nil)
        #expect(HTMLPreviewFind.command(forKey: "g", modifiers: [.command, .control]) == nil)
        #expect(HTMLPreviewFind.command(forKey: "g", modifiers: [.control]) == nil)
        #expect(HTMLPreviewFind.command(forKey: "h", modifiers: [.command]) == nil)
        #expect(HTMLPreviewFind.command(forKey: "", modifiers: [.command]) == nil)
    }
}

@MainActor
struct HTMLPreviewFindTests {
    private static let page = "<!doctype html><title>ready</title><p>alpha beta alpha</p>"

    private func makeHarness() async throws -> BrowserHarness {
        let harness = try BrowserHarness(files: ["site/page.html": "disk", "site/other.html": "<title>other</title><p>alpha</p>"])
        harness.show(Self.page)
        #expect(await harness.waitForTitle("ready"), "Title was \(harness.webView.title ?? "nil")")
        return harness
    }

    /// The text WebKit selected for the match and where it starts in its paragraph.
    private func selection(in harness: BrowserHarness) async throws -> (text: String, offset: Int) {
        let values = try #require(try await harness.evaluate("[String(getSelection()), getSelection().anchorOffset]") as? [Any])
        return (values[0] as? String ?? "", (values[1] as? NSNumber)?.intValue ?? -1)
    }

    /// Runs `action` and waits for WebKit to answer the search it started.
    private func searching(_ find: HTMLPreviewFindModel, in harness: BrowserHarness, _ action: () -> Void) async {
        let before = find.completedSearches
        action()
        #expect(await harness.wait { find.completedSearches > before }, "The search was never answered")
    }

    @Test func shortcutsAreOnlyAnsweredWhileThePageHasFocus() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        let surface = try #require(harness.webView as? HTMLPreviewWebViewSurface)
        var finds: [HTMLPreviewFind.Command] = []
        var prints: [HTMLPreviewPrint.Command] = []
        surface.onFindCommand = { finds.append($0) }
        surface.onPrintCommand = { prints.append($0) }

        // In the app the editor sits beside the preview and owns these shortcuts.
        let elsewhere = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        harness.window.contentView?.addSubview(elsewhere)
        #expect(harness.window.makeFirstResponder(elsewhere))
        _ = surface.performKeyEquivalent(with: harness.keyEvent("f", modifiers: .command))
        _ = surface.performKeyEquivalent(with: harness.keyEvent("p", modifiers: .command))
        #expect(finds.isEmpty)
        #expect(prints.isEmpty)

        #expect(harness.window.makeFirstResponder(surface))
        #expect(surface.performKeyEquivalent(with: harness.keyEvent("f", modifiers: .command)))
        #expect(surface.performKeyEquivalent(with: harness.keyEvent("g", modifiers: .command)))
        #expect(surface.performKeyEquivalent(with: harness.keyEvent("G", modifiers: [.command, .shift])))
        #expect(surface.performKeyEquivalent(with: harness.keyEvent("p", modifiers: .command)))
        #expect(finds == [.show, .next, .previous])
        #expect(prints == [.print])

        _ = surface.performKeyEquivalent(with: harness.keyEvent("f", modifiers: [.command, .option]))
        #expect(finds.count == 3)
    }

    @Test func findSelectsMatchesAndStepsThroughThemWithWrapping() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find

        find.handle(.show)
        #expect(find.isVisible)
        await searching(find, in: harness) { find.query = "alpha" }
        #expect(find.status == .found)
        #expect(try await selection(in: harness) == ("alpha", 0))

        await searching(find, in: harness) { find.step(backwards: false) }
        #expect(try await selection(in: harness) == ("alpha", 11))
        await searching(find, in: harness) { find.step(backwards: false) }
        #expect(try await selection(in: harness) == ("alpha", 0))
        await searching(find, in: harness) { find.step(backwards: true) }
        #expect(try await selection(in: harness) == ("alpha", 11))
    }

    @Test func typingMoreLettersKeepsTheMatchWhereItIs() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find
        find.handle(.show)

        for text in ["a", "al", "alp", "alpha b"] {
            await searching(find, in: harness) { find.query = text }
            #expect(try await selection(in: harness) == (text, 0), "Typing \(text) moved the match")
        }
    }

    @Test func findReportsMissingTextAndEmptyingTheFieldClearsTheResult() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find
        find.handle(.show)

        await searching(find, in: harness) { find.query = "zzz" }
        #expect(find.status == .notFound)
        await searching(find, in: harness) { find.query = "beta" }
        #expect(find.status == .found)
        find.query = ""
        #expect(find.status == .idle)
    }

    @Test func aSearchSupersededWhileItWasPendingDoesNotWinTheRace() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find
        find.handle(.show)

        find.query = "zzz"
        await searching(find, in: harness) { find.query = "beta" }
        #expect(find.status == .found)
        #expect(try await selection(in: harness) == ("beta", 6))
    }

    @Test func closingTheBarHidesItAndReopeningFindsTheTextAgain() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find
        find.handle(.show)
        await searching(find, in: harness) { find.query = "beta" }

        find.hide()
        #expect(!find.isVisible)
        #expect(find.status == .idle)
        // The match stays selected, so the next keystroke or copy acts on it.
        #expect(try await selection(in: harness) == ("beta", 6))

        await searching(find, in: harness) { find.handle(.show) }
        #expect(find.isVisible)
        #expect(find.status == .found)
        #expect(find.query == "beta")
    }

    @Test func findNextOpensTheBarAndSearchesOnlyWhenThereIsTextToFind() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find

        find.handle(.next)
        #expect(find.isVisible)
        #expect(find.completedSearches == 0)

        await searching(find, in: harness) { find.query = "alpha" }
        find.hide()
        await searching(find, in: harness) { find.handle(.previous) }
        #expect(find.isVisible)
        #expect(find.status == .found)
    }

    @Test func aNewPageClearsTheResultButKeepsTheBarAndItsText() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let find = harness.controller.find
        find.handle(.show)
        await searching(find, in: harness) { find.query = "alpha" }
        #expect(find.status == .found)

        #expect(harness.controller.navigate(toAddress: harness.fixture.url("site/other.html").path))
        #expect(await harness.waitForTitle("other"))
        #expect(find.status == .idle)
        #expect(find.isVisible)
        #expect(find.query == "alpha")
    }
}
