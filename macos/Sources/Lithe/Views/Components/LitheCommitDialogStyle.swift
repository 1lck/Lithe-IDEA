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
            .background(LitheCommitDialogStyle.editorBackground)
            .overlay {
                Rectangle().strokeBorder(focused ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                                         lineWidth: focused ? 2 : 1)
            }
    }
}

struct LitheCommitDialogButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LitheTheme.uiFont(size: 13))
            .foregroundStyle(primary ? .white : LitheTheme.primaryText)
            .padding(.horizontal, LitheTheme.Commit.buttonHorizontalPadding)
            .frame(minWidth: 72, minHeight: 28)
            .background(primary ? LitheTheme.settingsControlAccent : LitheCommitDialogStyle.background)
            .overlay {
                if hovering || configuration.isPressed { Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(primary ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder, lineWidth: 1)
            }
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

/// IDEA DarculaButtonUI/Painter: 28pt visible control, 3pt border insets,
/// 14pt label padding, 72pt minimum width, and regular UI font on macOS.
struct LitheActionButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
        configuration.label
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(isEnabled ? (isPrimary ? Color.white : LitheTheme.searchFieldText) : LitheTheme.Commit.disabledText)
            .padding(.horizontal, LitheTheme.Commit.buttonHorizontalPadding)
            .frame(minWidth: LitheTheme.Commit.buttonMinimumWidth, minHeight: LitheTheme.Commit.buttonHeight)
            .background(shape.fill(isPrimary && isEnabled ? LitheTheme.searchFieldFocusBorder
                                                          : isEnabled ? LitheTheme.Commit.buttonBackground(for: colorScheme) : .clear))
            .overlay(shape.strokeBorder(isEnabled ? (isPrimary ? LitheTheme.searchFieldFocusBorder : LitheTheme.searchFieldBorder)
                                                  : LitheTheme.Commit.disabledBorder, lineWidth: 1))
            .padding(LitheTheme.Commit.buttonBorderInset)
            .contentShape(Rectangle())
    }
}
