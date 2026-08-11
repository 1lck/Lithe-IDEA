import AppKit
import SwiftUI

enum LitheTheme {
    // MARK: - 背景层次
    // 从深到浅：window < sidebar < editor < raised。层间对比度刻意拉开，
    // 让工具窗口、编辑区和浮层在暗色下依然能区分出前后关系。
    static let window = Color(red: 0.106, green: 0.113, blue: 0.125)
    static let titlebar = Color(red: 0.145, green: 0.155, blue: 0.169)
    static let toolHeader = Color(red: 0.122, green: 0.130, blue: 0.142)
    static let sidebar = Color(red: 0.090, green: 0.096, blue: 0.106)
    static let editor = Color(red: 0.074, green: 0.079, blue: 0.088)
    static let raised = Color(red: 0.165, green: 0.175, blue: 0.190)

    // MARK: - 选中与悬停
    static let selection = Color(red: 0.170, green: 0.290, blue: 0.490)
    static let subtleSelection = Color(red: 0.205, green: 0.218, blue: 0.238)
    static let hoverBackground = Color.white.opacity(0.055)
    static let pressedBackground = Color.white.opacity(0.095)

    // MARK: - 标签页
    static let activeTabBackground = Color(red: 0.145, green: 0.155, blue: 0.170)
    static let inactiveTabBackground = Color.clear
    static let tabUnderline = Color(red: 0.31, green: 0.58, blue: 0.98)

    // MARK: - 分隔与边框
    static let divider = Color.white.opacity(0.075)
    static let panelBorder = Color.white.opacity(0.13)

    // MARK: - 输入控件
    static let inputBackground = Color(red: 0.065, green: 0.070, blue: 0.078)
    static let inputBorder = Color.white.opacity(0.12)
    static let inputFocusBorder = Color(red: 0.31, green: 0.58, blue: 0.98).opacity(0.85)

    // MARK: - 浮层
    static let popupBackground = Color(red: 0.135, green: 0.143, blue: 0.157)
    static let popupShadow = Color.black.opacity(0.55)
    static let badgeBackground = Color.white.opacity(0.10)

    // MARK: - 文本
    static let primaryText = Color.white.opacity(0.86)
    static let secondaryText = Color.white.opacity(0.50)
    static let tertiaryText = Color.white.opacity(0.34)

    // MARK: - 语义色
    static let accent = Color(red: 0.31, green: 0.58, blue: 0.98)
    static let success = Color(red: 0.28, green: 0.72, blue: 0.39)
    static let warning = Color(red: 0.91, green: 0.63, blue: 0.20)
    static let error = Color(red: 0.92, green: 0.33, blue: 0.33)
    /// Cmd/Ctrl 悬停时标识符转成的“可点击”色。
    static let link = Color(red: 0.42, green: 0.68, blue: 1.00)
    // 语义化别名，便于 AppKit 装饰代码与设计稿 token 同名。
    static let linkColor = link

    // MARK: - 编辑器缩进竖线
    static let guide = Color.white.opacity(0.085)
    static let activeGuide = Color.white.opacity(0.24)
    static let guideColor = guide
    static let activeGuideColor = activeGuide

    static let uiFont = Font.system(size: 14, weight: .regular)
    static let smallFont = Font.system(size: 12, weight: .regular)
    static let codeFont = Font.system(size: 13, design: .monospaced)

    /// 统一的尺寸与间距刻度，避免各视图各写一套魔法数字。
    enum Metrics {
        static let rowHeight: CGFloat = 24
        static let treeRowHeight: CGFloat = 27
        static let treeIconSize: CGFloat = 16
        static let treeFontSize: CGFloat = 13.5
        static let tabHeight: CGFloat = 34
        static let toolbarHeight: CGFloat = 40
        static let toolWindowHeaderHeight: CGFloat = 30
        static let statusBarHeight: CGFloat = 24
        static let cornerRadius: CGFloat = 5
        static let popupCornerRadius: CGFloat = 10
        static let controlCornerRadius: CGFloat = 6
    }
}

extension View {
    func litheIconButton() -> some View {
        self
            .buttonStyle(LitheIconButtonStyle())
            .lithePointer()
    }

    /// Shows the macOS pointing-hand cursor while an interactive control is
    /// hovered. The push/pop pair is balanced even when a view disappears.
    func lithePointer() -> some View {
        modifier(LithePointerModifier())
    }

    /// 给行/单元格加统一的悬停高亮，替代各处手写的 onHover + background。
    func litheRowHover(
        isActive: Bool = false,
        cornerRadius: CGFloat = LitheTheme.Metrics.cornerRadius,
        activeBackground: Color = LitheTheme.selection,
        hoverBackground: Color = LitheTheme.hoverBackground,
        animation: Animation? = .easeOut(duration: 0.12)
    ) -> some View {
        modifier(
            LitheRowHoverModifier(
                isActive: isActive,
                cornerRadius: cornerRadius,
                activeBackground: activeBackground,
                hoverBackground: hoverBackground,
                animation: animation
            )
        )
    }
}

struct LitheIconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                    .fill(
                        configuration.isPressed
                            ? LitheTheme.pressedBackground
                            : (isHovering ? LitheTheme.hoverBackground : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Keeps file-tree rows visually stable while they are being activated.
struct LitheTreeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct LitheRowHoverModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let activeBackground: Color
    let hoverBackground: Color
    let animation: Animation?
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isActive ? activeBackground : (isHovering ? hoverBackground : .clear))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(animation, value: isHovering)
    }
}

// MARK: - 按钮样式

struct LithePrimaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(LitheTheme.accent.opacity(configuration.isPressed ? 0.78 : (isHovering ? 1 : 0.92)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }
}

struct LitheSecondaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(configuration.isPressed ? LitheTheme.subtleSelection : (isHovering ? LitheTheme.raised : LitheTheme.raised.opacity(0.72)))
            )
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .stroke(LitheTheme.panelBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }
}

private struct LithePointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isPointing = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                isHovered = isInside
                updateCursor(isPointing: isInside && isEnabled)
            }
            .onChange(of: isEnabled) { _ in
                updateCursor(isPointing: isHovered && isEnabled)
            }
            .onDisappear {
                isHovered = false
                updateCursor(isPointing: false)
            }
    }

    private func updateCursor(isPointing newValue: Bool) {
        guard newValue != isPointing else { return }
        isPointing = newValue
        if newValue {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }
}

// MARK: - 输入框样式

/// 统一的搜索/文本输入外观：暗底 + 1pt 边框，聚焦时边框转 accent。
struct LitheSearchFieldStyle: ViewModifier {
    var isFocused: Bool
    var height: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(LitheTheme.inputBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .stroke(isFocused ? LitheTheme.inputFocusBorder : LitheTheme.inputBorder, lineWidth: 1)
            }
    }
}

extension View {
    func litheSearchField(isFocused: Bool = false, height: CGFloat = 28) -> some View {
        modifier(LitheSearchFieldStyle(isFocused: isFocused, height: height))
    }

    /// 浮层统一外观：圆角、背景、1pt 边框和投影。
    func lithePopupChrome(cornerRadius: CGFloat = LitheTheme.Metrics.popupCornerRadius) -> some View {
        self
            .background(LitheTheme.popupBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(LitheTheme.panelBorder, lineWidth: 1)
            }
            .shadow(color: LitheTheme.popupShadow, radius: 30, y: 14)
    }
}
