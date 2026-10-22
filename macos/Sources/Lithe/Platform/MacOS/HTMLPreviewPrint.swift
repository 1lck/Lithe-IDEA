import AppKit
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// The shortcut that prints the page while it has focus.
enum HTMLPreviewPrint {
    enum Command: Equatable {
        case print
    }

    /// Maps ⌘P to a print command. Any other modifier means the shortcut belongs to someone else.
    static func command(forKey key: String, modifiers: NSEvent.ModifierFlags) -> Command? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags == [.command], key.lowercased() == "p" else { return nil }
        return .print
    }
}

/// The name a saved PDF of the page starts with.
enum HTMLPreviewPDF {
    private static let maximumNameLength = 100

    /// The page title when it has one, else `fallback`, cleaned for use as a file name.
    static func name(title: String?, fallback: String) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stem = trimmedTitle.isEmpty ? fallback : trimmedTitle
        let separators = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = stem.components(separatedBy: separators).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let name = String(cleaned.prefix(maximumNameLength))
        return name.isEmpty ? "page" : name
    }

    static func fileName(title: String?, fallback: String) -> String {
        name(title: title, fallback: fallback) + ".pdf"
    }
}

/// WebKit's right-click menu, adjusted for a preview that has one tab.
enum HTMLPreviewContextMenu {
    /// WebKit tags its own items with these identifiers; the Swift constants for them are not public.
    private static let webKitPrefix = "WKMenuItemIdentifier"
    private static let reloadIdentifier = "WKMenuItemIdentifierReload"
    private static let inspectElementIdentifier = "WKMenuItemIdentifierInspectElement"

    static let printIdentifier = NSUserInterfaceItemIdentifier("LitheHTMLPreviewPrint")
    static let exportPDFIdentifier = NSUserInterfaceItemIdentifier("LitheHTMLPreviewExportPDF")

    /// Removes the "in New Window" items, which would only load the same page in
    /// place, and puts `pageActions` on the menu of the page background (the one
    /// with Reload) above Inspect Element. Link, text and image menus keep what
    /// WebKit built, including Copy Link and Inspect Element.
    static func customize(_ menu: NSMenu, pageActions: [NSMenuItem]) {
        for item in menu.items where isNewWindowItem(item) { menu.removeItem(item) }

        let isPageBackground = menu.items.contains { $0.identifier?.rawValue == reloadIdentifier }
        let hasActions = menu.items.contains { $0.identifier == printIdentifier || $0.identifier == exportPDFIdentifier }
        if isPageBackground && !hasActions && !pageActions.isEmpty {
            if let inspect = menu.items.firstIndex(where: { $0.identifier?.rawValue == inspectElementIdentifier }) {
                for (offset, item) in (pageActions + [NSMenuItem.separator()]).enumerated() {
                    menu.insertItem(item, at: inspect + offset)
                }
            } else {
                for item in [NSMenuItem.separator()] + pageActions { menu.addItem(item) }
            }
        }
        removeRedundantSeparators(from: menu)
    }

    private static func isNewWindowItem(_ item: NSMenuItem) -> Bool {
        guard let identifier = item.identifier?.rawValue else { return false }
        return identifier.hasPrefix(webKitPrefix) && identifier.hasSuffix("InNewWindow")
    }

    /// A menu starts and ends with an item and never shows two separators in a row.
    private static func removeRedundantSeparators(from menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

extension HTMLPreviewBrowserController {
    func handlePrintCommand(_ command: HTMLPreviewPrint.Command) {
        switch command {
        case .print: printPage()
        }
    }

    /// Adjusts the context menu WebKit built for a right-click, before it appears.
    func customizeContextMenu(_ menu: NSMenu, for event: NSEvent?) {
        let print = NSMenuItem(title: String(localized: "Print…"), action: #selector(printPageFromMenu(_:)), keyEquivalent: "")
        print.identifier = HTMLPreviewContextMenu.printIdentifier
        print.target = self
        let export = NSMenuItem(title: String(localized: "Export as PDF…"), action: #selector(exportPDFFromMenu(_:)), keyEquivalent: "")
        export.identifier = HTMLPreviewContextMenu.exportPDFIdentifier
        export.target = self
        HTMLPreviewContextMenu.customize(menu, pageActions: [print, export])
    }

    /// Shows the print panel for the page as a sheet on the preview's window.
    func printPage() {
        guard webView.url != nil else { return }
        let operation = webView.printOperation(with: (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo())
        // The print panel offers this as the name when the page is saved as a PDF from there.
        operation.jobTitle = HTMLPreviewPDF.name(title: webView.title, fallback: pageFileStem)
        // The page is laid out in the frame of the operation's view, which starts out empty.
        operation.view?.frame = webView.bounds
        dialogs.runPrintOperation(operation, in: webView.window)
    }

    /// Saves the page as one continuous PDF page. The print panel's PDF menu
    /// makes the paginated version.
    func exportPageAsPDF() async {
        guard webView.url != nil else { return }
        let name = HTMLPreviewPDF.fileName(title: webView.title, fallback: pageFileStem)
        let destination: URL? = await withCheckedContinuation { continuation in
            dialogs.chooseDownloadDestination(suggestedFilename: name, in: webView.window) { continuation.resume(returning: $0) }
        }
        guard let destination else { return }
        do {
            let data = try await webView.pdf()
            try await Task.detached { try data.write(to: destination, options: .atomic) }.value
        } catch {
            report(error)
        }
    }

    /// What the page is called when it has no title: the file for the document being
    /// previewed, the host for anything else.
    private var pageFileStem: String {
        guard let url = webView.url else { return "page" }
        if HTMLPreviewURL.isInternal(url) {
            return URL(fileURLWithPath: sourceLabel(for: url)).deletingPathExtension().lastPathComponent
        }
        return url.host ?? "page"
    }

    @objc private func printPageFromMenu(_ sender: Any?) {
        printPage()
    }

    @objc private func exportPDFFromMenu(_ sender: Any?) {
        Task { await exportPageAsPDF() }
    }
}
