import AppKit
import LitheModuleAPI

/// The shared presenter's system-integration route. AppKit owns geometry, focus,
/// submenu tracking, accessibility and appearance; callers supply only actions.
// Note: .agents/notes/implemented/feature/2026-11-03-macos-open-with.md
@MainActor
enum LitheSystemContextMenu {
    static func makeMenu(items: [LitheContextMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if case .separator = item.kind {
                menu.addItem(.separator())
                continue
            }
            let title = item.localizesTitle ? L10n.string(key: item.title) : item.title
            let native = LitheSystemContextMenuAction(title: title, perform: item.action)
            native.isEnabled = item.isEnabled
            native.state = item.isChecked ? .on : .off
            native.toolTip = item.description
            if let description = item.description, !description.isEmpty {
                // Session IDs distinguish conversations with identical titles.
                // Preserve that visible context when the whole file menu uses AppKit.
                if #available(macOS 14.4, *) {
                    native.subtitle = description
                } else {
                    native.title = String(format: L10n.string("%@ — %@"), title, description)
                }
            }
            if let image = item.nativeImage {
                native.image = image.copy() as? NSImage
                native.image?.size = NSSize(width: 16, height: 16)
            } else if let kind = item.iconKind {
                native.image = LitheIcons.nsImage(kind, size: 16)
            } else if let symbol = item.systemImage {
                native.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            if let shortcut = item.shortcut, let key = shortcut.last, key.isLetter {
                native.keyEquivalent = String(key).lowercased()
                native.keyEquivalentModifierMask = []
                if shortcut.contains("⌘") { native.keyEquivalentModifierMask.insert(.command) }
                if shortcut.contains("⇧") { native.keyEquivalentModifierMask.insert(.shift) }
                if shortcut.contains("⌥") { native.keyEquivalentModifierMask.insert(.option) }
                if shortcut.contains("⌃") { native.keyEquivalentModifierMask.insert(.control) }
            }
            if case .submenu(let children) = item.kind {
                native.submenu = makeMenu(items: children)
            }
            menu.addItem(native)
        }
        return menu
    }
}

@MainActor
private final class LitheSystemContextMenuAction: NSMenuItem {
    private let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { perform() }
}
