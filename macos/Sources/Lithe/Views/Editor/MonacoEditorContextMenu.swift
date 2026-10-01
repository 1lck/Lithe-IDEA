import AppKit
import SwiftUI
import WebKit

/// Presentation only: Monaco still owns menu membership, availability and action execution.
@MainActor
final class MonacoEditorContextMenu {
    struct Item: Decodable {
        let key: String
        let id: String
        let title: String
        let enabled: Bool
        let checked: Bool
        let shortcut: String?
        let separator: Bool?
        let children: [Item]?
    }
    struct Request: Decodable {
        let x: Double
        let y: Double
        let items: [Item]

        static func decode(_ body: [String: Any]) throws -> Self {
            guard JSONSerialization.isValidJSONObject(body) else { throw CocoaError(.coderInvalidValue) }
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= 1_048_576 else { throw CocoaError(.coderInvalidValue) }
            let request = try JSONDecoder().decode(Self.self, from: data)
            var keys = Set<String>()
            func validate(_ items: [Item], depth: Int) -> Bool {
                guard depth <= 8 else { return false }
                for item in items {
                    guard keys.insert(item.key).inserted, keys.count <= 500,
                          item.title.count <= 8_192, item.id.count <= 512,
                          item.key.count <= 512, (item.shortcut?.count ?? 0) <= 512 else { return false }
                    if let children = item.children, !validate(children, depth: depth + 1) { return false }
                }
                return true
            }
            guard request.x.isFinite, request.y.isFinite, !request.items.isEmpty,
                  validate(request.items, depth: 0) else { throw CocoaError(.coderInvalidValue) }
            return request
        }
    }

    private let presenter = LitheContextMenuPresenter()

    // IDEA action definitions + PlatformIconMappings, revision c7f91397daa3a961b4e78bc634fe467a0a7d9ade.
    // An action without a matching Presentation.icon keeps its icon slot empty.
    static func iconPath(for id: String) -> String? {
        switch id {
        case "editor.action.clipboardCutAction": "expui/general/cut.svg"
        case "editor.action.clipboardCopyAction", "editor.action.clipboardCopyWithSyntaxHighlightingAction": "expui/general/copy.svg"
        case "editor.action.clipboardPasteAction": "expui/general/paste.svg"
        case "editor.action.formatDocument", "editor.action.formatSelection": "expui/actions/reformatCode.svg"
        case "lithe.javaRun.run", "lithe.javaRun.popup.run": "debugger/run.svg"
        case "lithe.javaRun.debug", "lithe.javaRun.popup.debug": "debugger/debug.svg"
        case "lithe.runToCursor": "debugger/runToCursor.svg"
        default: nil
        }
    }

    static func menuItems(_ items: [Item], select: @escaping (String) -> Void) -> [LitheContextMenuItem] {
        items.map { item in
            if item.separator == true { return .separator }
            var result: LitheContextMenuItem
            if let children = item.children {
                result = .submenu(item.title, items: menuItems(children, select: select))
                result.isEnabled = item.enabled
                result.isChecked = item.checked
            } else {
                result = .action(item.title, checked: item.checked, shortcut: item.shortcut,
                                 isEnabled: item.enabled) { select(item.key) }
            }
            if let path = iconPath(for: item.id) {
                result.icon = AnyView(LitheIDEAIcon(resourcePath: path, size: 16, preservesOriginalColors: true))
            }
            return result
        }
    }

    func show(_ request: Request, in webView: WKWebView, completion: @escaping (String?) -> Void) {
        guard let window = webView.window else { completion(nil); return }
        // CSS pixels are logical points at pageZoom == 1, independent of Retina scale.
        let x = min(max(CGFloat(request.x) * webView.pageZoom, 0), webView.bounds.width)
        let y = min(max(CGFloat(request.y) * webView.pageZoom, 0), webView.bounds.height)
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        let screenPoint = window.convertToScreen(NSRect(origin: webView.convert(point, to: nil), size: .zero)).origin
        var selected: String?
        let items = Self.menuItems(request.items) { selected = $0 }
        presenter.show(items: items, at: screenPoint, appearance: webView.effectiveAppearance,
                       locale: Locale.current, parentWindow: window) { [weak webView, weak window] in
            // The shared presenter dismisses before calling an item's action. Reply
            // on the next turn so a selected action cannot be mistaken for cancellation.
            DispatchQueue.main.async {
                if selected != nil, let webView, let window, webView.window === window {
                    window.makeKey()
                    window.makeFirstResponder(webView)
                    completion(selected)
                } else { completion(nil) }
            }
        }
    }

    func dismiss() { presenter.dismiss() }
    isolated deinit { presenter.dismiss() }
}
