import AppKit
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// Browser-style page zoom for the HTML preview: the stops "+" and "−" walk
/// through, and the keyboard shortcuts that drive them.
enum HTMLPreviewZoom {
    enum Command: Equatable {
        case zoomIn
        case zoomOut
        case reset
    }

    /// The stops of a desktop browser's zoom menu, so the percentage shown is
    /// always one the user would recognise.
    static let levels: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5
    ]
    static let defaultLevel = 1.0

    /// Page zoom is a float the web view may round, so stops are compared with a margin.
    private static let tolerance = 0.001

    /// The next stop above `factor`, or nil at the largest.
    static func zoomedIn(from factor: Double) -> Double? {
        levels.first { $0 > factor + tolerance }
    }

    /// The next stop below `factor`, or nil at the smallest.
    static func zoomedOut(from factor: Double) -> Double? {
        levels.last { $0 < factor - tolerance }
    }

    static func percent(_ factor: Double) -> Int {
        Int((factor * 100).rounded())
    }

    /// Maps ⌘+, ⌘= (the same key without Shift), ⌘− and ⌘0 to a zoom command.
    /// Any other modifier means the shortcut belongs to someone else.
    static func command(forKey key: String, modifiers: NSEvent.ModifierFlags) -> Command? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), flags.isDisjoint(with: [.option, .control]) else { return nil }
        switch key {
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        case "0": return .reset
        default: return nil
        }
    }
}

/// Hands the page shortcuts (zoom, find, print) to the preview while the page
/// itself has focus. Key equivalents are offered to every view of the window, so
/// a preview shown beside the editor must not answer ⌘+ or ⌘F typed into the editor.
final class HTMLPreviewWebViewSurface: WKWebView {
    var onZoomCommand: ((HTMLPreviewZoom.Command) -> Void)?
    var onFindCommand: ((HTMLPreviewFind.Command) -> Void)?
    var onPrintCommand: ((HTMLPreviewPrint.Command) -> Void)?
    /// Called with the context menu WebKit is about to show, before it appears.
    var onContextMenu: ((NSMenu, NSEvent?) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags
        if let command = HTMLPreviewZoom.command(forKey: key, modifiers: modifiers) {
            onZoomCommand?(command)
            return true
        }
        if let command = HTMLPreviewFind.command(forKey: key, modifiers: modifiers) {
            onFindCommand?(command)
            return true
        }
        if let command = HTMLPreviewPrint.command(forKey: key, modifiers: modifiers) {
            onPrintCommand?(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        onContextMenu?(menu, event)
    }
}
