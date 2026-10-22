import SwiftUI

/// Welcome-page action chrome: 28pt visible control, no external focus insets,
/// 14pt label padding, 72pt minimum width, and regular UI font on macOS.
struct LitheActionButtonStyle: ButtonStyle {
    var isPrimary = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LitheTheme.ActionButton.cornerRadius)
        let destructive = configuration.role == .destructive
        let primaryColor = destructive ? LitheTheme.error : configuration.isPressed
            ? LitheTheme.ActionButton.primaryPressed
            : isHovered ? LitheTheme.ActionButton.primaryHover : LitheTheme.ActionButton.primary
        configuration.label
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(isEnabled ? (isPrimary ? Color.white : destructive ? LitheTheme.error : LitheTheme.searchFieldText) : LitheTheme.ActionButton.disabledText)
            .underline(isEnabled && isFocused)
            .padding(.horizontal, LitheTheme.ActionButton.horizontalPadding)
            .frame(minWidth: LitheTheme.ActionButton.minimumWidth,
                   minHeight: LitheTheme.ActionButton.height)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                shape.fill(isPrimary && isEnabled ? primaryColor
                                                  : isEnabled ? LitheTheme.ActionButton.background(for: colorScheme) : .clear)
                if isEnabled && isHovered && !isPrimary { shape.fill(LitheTheme.hoverBackground) }
            }
            .overlay(shape.strokeBorder(isEnabled ? (isPrimary ? primaryColor : LitheTheme.searchFieldBorder)
                                                  : LitheTheme.ActionButton.disabledBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .lithePointer()
            .litheFocusEffectHidden()
    }
}
