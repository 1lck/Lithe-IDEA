import SwiftUI

/// IDEA DarculaButtonUI/Painter: 28pt visible control, 3pt border insets,
/// 14pt label padding, 72pt minimum width, and regular UI font on macOS.
struct LitheActionButtonStyle: ButtonStyle {
    var isPrimary = false
    var borderInset: CGFloat = LitheTheme.Commit.buttonBorderInset
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
        configuration.label
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(isEnabled ? (isPrimary ? Color.white : LitheTheme.searchFieldText) : LitheTheme.Commit.disabledText)
            .padding(.horizontal, LitheTheme.Commit.buttonHorizontalPadding)
            .frame(minWidth: LitheTheme.Commit.buttonMinimumWidth, minHeight: LitheTheme.Commit.buttonHeight)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                shape.fill(isPrimary && isEnabled ? LitheTheme.searchFieldFocusBorder
                                                  : isEnabled ? LitheTheme.Commit.buttonBackground(for: colorScheme) : .clear)
                if isEnabled && isHovered { shape.fill(LitheTheme.hoverBackground) }
            }
            .overlay(shape.strokeBorder(isEnabled ? (isPrimary ? LitheTheme.searchFieldFocusBorder : LitheTheme.searchFieldBorder)
                                                  : LitheTheme.Commit.disabledBorder, lineWidth: 1))
            .padding(borderInset)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
