import AppKit
import SwiftUI

/// DialogWrapper / DarculaEditorTextFieldBorder, Islands themes. Initially used by Commit only.
enum LitheCommitDialogStyle {
    static let backgroundNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 25 / 255, green: 26 / 255, blue: 28 / 255, alpha: 1)
            : NSColor(srgbRed: 247 / 255, green: 248 / 255, blue: 249 / 255, alpha: 1)
    }
    static var background: Color { Color(nsColor: backgroundNSColor) }
    static var editorBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? backgroundNSColor : .white
        })
    }
}

struct LitheCommitDialogInputStyle: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(LitheTheme.uiFont(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28, alignment: .center)
            .litheTextEditingCursor()
            .litheSettingsControlChrome(
                background: LitheCommitDialogStyle.editorBackground,
                border: focused ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                lineWidth: focused ? 2 : 1
            )
    }
}
