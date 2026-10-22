import AppKit
import PDFKit
import Testing
import WebKit
@testable import Lithe

struct HTMLPreviewPrintShortcutTests {
    @Test func commandPPrints() {
        #expect(HTMLPreviewPrint.command(forKey: "p", modifiers: [.command]) == .print)
        #expect(HTMLPreviewPrint.command(forKey: "P", modifiers: [.command, .capsLock]) == .print)
    }

    @Test func otherKeyCombinationsAreLeftToTheirOwners() {
        #expect(HTMLPreviewPrint.command(forKey: "p", modifiers: []) == nil)
        #expect(HTMLPreviewPrint.command(forKey: "p", modifiers: [.command, .shift]) == nil)
        #expect(HTMLPreviewPrint.command(forKey: "p", modifiers: [.command, .option]) == nil)
        #expect(HTMLPreviewPrint.command(forKey: "p", modifiers: [.control]) == nil)
        #expect(HTMLPreviewPrint.command(forKey: "o", modifiers: [.command]) == nil)
        #expect(HTMLPreviewPrint.command(forKey: "", modifiers: [.command]) == nil)
    }

    @Test func pdfNamesComeFromTheTitleOrTheFallback() {
        #expect(HTMLPreviewPDF.fileName(title: "Quarterly Report", fallback: "page") == "Quarterly Report.pdf")
        #expect(HTMLPreviewPDF.fileName(title: "  Report \n", fallback: "page") == "Report.pdf")
        #expect(HTMLPreviewPDF.fileName(title: nil, fallback: "index") == "index.pdf")
        #expect(HTMLPreviewPDF.fileName(title: "", fallback: "example.com") == "example.com.pdf")
        #expect(HTMLPreviewPDF.name(title: "Report", fallback: "page") == "Report")
    }

    @Test func pdfNamesNeverContainPathSeparatorsOrGrowWithoutLimit() {
        #expect(HTMLPreviewPDF.fileName(title: "a/b:c\\d", fallback: "page") == "a-b-c-d.pdf")
        #expect(HTMLPreviewPDF.fileName(title: "..hidden", fallback: "page") == "hidden.pdf")
        #expect(HTMLPreviewPDF.fileName(title: "///", fallback: "page") == "---.pdf")
        #expect(HTMLPreviewPDF.fileName(title: "", fallback: "") == "page.pdf")
        let long = HTMLPreviewPDF.fileName(title: String(repeating: "x", count: 500), fallback: "page")
        #expect(long == String(repeating: "x", count: 100) + ".pdf")
    }
}

@MainActor
struct HTMLPreviewContextMenuTests {
    /// Builds a menu the way WebKit does: its items carry `WKMenuItemIdentifier…` identifiers; "-" is a separator.
    private func menu(_ entries: [String]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            if entry == "-" {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + entry)
            menu.addItem(item)
        }
        return menu
    }

    private func layout(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "-" }
            return item.identifier?.rawValue.replacingOccurrences(of: "WKMenuItemIdentifier", with: "") ?? item.title
        }
    }

    private func customized(_ entries: [String]) -> (controller: HTMLPreviewBrowserController, menu: NSMenu) {
        let controller = HTMLPreviewBrowserController(dialogs: RecordingDialogs())
        let menu = menu(entries)
        controller.customizeContextMenu(menu, for: nil)
        return (controller, menu)
    }

    private let printID = HTMLPreviewContextMenu.printIdentifier.rawValue
    private let exportID = HTMLPreviewContextMenu.exportPDFIdentifier.rawValue

    // The entries below are the menus WebKit built for a right-click on this macOS, recorded from a real web view.

    @Test func theMenuOfThePageBackgroundGainsPrintAndExportAboveInspectElement() {
        let result = customized(["Reload", "-", "-", "InspectElement"])
        #expect(layout(result.menu) == ["Reload", "-", printID, exportID, "-", "InspectElement"])
        #expect(result.menu.items.filter { !$0.isSeparatorItem }.map(\.title).contains(String(localized: "Print…")))
    }

    @Test func historyItemsStayAboveReload() {
        let result = customized(["GoBack", "GoForward", "Reload", "-", "InspectElement"])
        #expect(layout(result.menu) == ["GoBack", "GoForward", "Reload", "-", printID, exportID, "-", "InspectElement"])
    }

    @Test func withoutInspectElementTheActionsEndTheMenu() {
        #expect(layout(customized(["Reload"]).menu) == ["Reload", "-", printID, exportID])
    }

    @Test func linkMenusLoseOnlyTheNewWindowItem() {
        let result = customized([
            "OpenLink", "OpenLinkInNewWindow", "DownloadLinkedFile", "-", "CopyLink", "ShareMenu", "-", "InspectElement"
        ])
        #expect(layout(result.menu) == ["OpenLink", "DownloadLinkedFile", "-", "CopyLink", "ShareMenu", "-", "InspectElement"])
    }

    @Test func imageMenusLoseOnlyTheNewWindowItem() {
        let result = customized(["OpenImageInNewWindow", "DownloadImage", "CopyImage", "-", "InspectElement"])
        #expect(layout(result.menu) == ["DownloadImage", "CopyImage", "-", "InspectElement"])
    }

    @Test func textMenusAreLeftAlone() {
        let entries = ["LookUp", "Translate", "SearchWeb", "-", "Copy", "-", "InspectElement"]
        #expect(layout(customized(entries).menu) == entries)
    }

    @Test func customizingTwiceDoesNotDuplicateTheActions() {
        let result = customized(["Reload", "-", "InspectElement"])
        result.controller.customizeContextMenu(result.menu, for: nil)
        #expect(layout(result.menu) == ["Reload", "-", printID, exportID, "-", "InspectElement"])
    }

    @Test func theAddedItemsPrintAndExportThroughTheController() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("<!doctype html><title>Menu Page</title><p>hello</p>")
        #expect(await harness.waitForTitle("Menu Page"))

        let menu = menu(["Reload", "-", "InspectElement"])
        harness.controller.customizeContextMenu(menu, for: nil)
        let printItem = try #require(menu.items.first { $0.identifier == HTMLPreviewContextMenu.printIdentifier })
        let exportItem = try #require(menu.items.first { $0.identifier == HTMLPreviewContextMenu.exportPDFIdentifier })
        #expect(printItem.target === harness.controller)
        #expect(exportItem.target === harness.controller)

        let action = try #require(printItem.action)
        #expect(NSApplication.shared.sendAction(action, to: printItem.target, from: printItem))
        #expect(harness.dialogs.printOperations.count == 1)
    }
}

@MainActor
struct HTMLPreviewPrintTests {
    @Test func printingHandsTheDialogsAnOperationLaidOutForThePage() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("<!doctype html><title>Report</title><p>hello</p>")
        #expect(await harness.waitForTitle("Report"))

        harness.controller.handlePrintCommand(.print)

        let operation = try #require(harness.dialogs.printOperations.first)
        #expect(harness.dialogs.printOperations.count == 1)
        #expect(operation.jobTitle == "Report")
        #expect(operation.view?.frame == harness.webView.bounds)
    }

    @Test func thereIsNothingToPrintBeforeAPageIsShown() throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.controller.handlePrintCommand(.print)
        #expect(harness.dialogs.printOperations.isEmpty)
    }

    @Test func exportingWritesTheWholePageToTheChosenFile() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("""
            <!doctype html><title>Long Report</title>
            <body style="margin:0"><div style="height:3000px;background:#eee">tall</div></body>
            """)
        #expect(await harness.waitForTitle("Long Report"))
        let destination = harness.fixture.root.appendingPathComponent("out.pdf")
        harness.dialogs.downloadDestination = destination

        await harness.controller.exportPageAsPDF()

        #expect(harness.dialogs.downloadNames == ["Long Report.pdf"])
        #expect(harness.controller.loadError == nil)
        let document = try #require(PDFDocument(url: destination))
        #expect(document.pageCount >= 1)
        let height = try #require(document.page(at: 0)).bounds(for: .mediaBox).height
        #expect(height > 1500, "Only \(height) points of a 3000-point page were exported")
    }

    @Test func cancellingTheSavePanelWritesNothing() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("<!doctype html><title>Cancelled</title><p>hello</p>")
        #expect(await harness.waitForTitle("Cancelled"))
        harness.dialogs.downloadDestination = nil

        await harness.controller.exportPageAsPDF()

        #expect(harness.dialogs.downloadNames == ["Cancelled.pdf"])
        #expect(harness.controller.loadError == nil)
    }

    @Test func anUnwritableDestinationIsReportedToTheUser() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("<!doctype html><title>Unwritable</title><p>hello</p>")
        #expect(await harness.waitForTitle("Unwritable"))
        harness.dialogs.downloadDestination = harness.fixture.root.appendingPathComponent("missing/out.pdf")

        await harness.controller.exportPageAsPDF()

        #expect(harness.controller.loadError != nil)
    }
}
