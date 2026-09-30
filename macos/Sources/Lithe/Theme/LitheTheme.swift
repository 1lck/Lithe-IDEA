import AppKit
import SwiftUI

enum LitheTheme {
    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        init(_ hex: UInt32, alpha: CGFloat = 1) {
            red = CGFloat((hex >> 16) & 0xff) / 255
            green = CGFloat((hex >> 8) & 0xff) / 255
            blue = CGFloat(hex & 0xff) / 255
            self.alpha = alpha
        }

        func withAlpha(_ alpha: CGFloat) -> RGBA {
            RGBA(red: red, green: green, blue: blue, alpha: alpha)
        }

        func mixed(with other: RGBA, amount: CGFloat) -> RGBA {
            let amount = min(max(amount, 0), 1)
            return RGBA(
                red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount,
                alpha: alpha + (other.alpha - alpha) * amount
            )
        }

        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    private struct Palette {
        let window: RGBA
        let titlebar: RGBA
        let toolHeader: RGBA
        let toolHeaderInactive: RGBA
        let sidebar: RGBA
        let editor: RGBA
        let raised: RGBA
        let notification: RGBA
        let selection: RGBA
        let subtleSelection: RGBA
        let hoverBackground: RGBA
        let pressedBackground: RGBA
        let activeTabBackground: RGBA
        let tabUnderline: RGBA
        let diffInformationBackground: RGBA
        let diffInformationText: RGBA
        let divider: RGBA
        let panelBorder: RGBA
        let inputBackground: RGBA
        let inputBorder: RGBA
        let inputFocusBorder: RGBA
        let popupBackground: RGBA
        let popupShadow: RGBA
        let badgeBackground: RGBA
        let primaryText: RGBA
        let secondaryText: RGBA
        let tertiaryText: RGBA
        let toolWindowText: RGBA
        let toolWindowButtonText: RGBA
        let toolWindowSelectedText: RGBA
        let accent: RGBA
        let runAction: RGBA
        let success: RGBA
        let warning: RGBA
        let error: RGBA
        let skill: RGBA
        let link: RGBA
        let guide: RGBA
        let activeGuide: RGBA

        static func make(theme: AppColorTheme, isDark: Bool) -> Palette {
            let surface: RGBA
            let ink: RGBA
            let accent: RGBA
            let diffAdded: RGBA
            let diffRemoved: RGBA
            let skill: RGBA
            let contrast: CGFloat

            switch (theme, isDark) {
            case (.lithe, _):
                return lithe(isDark: isDark)
            case (.codex, true):
                surface = RGBA(0x111111)
                ink = RGBA(0xfcfcfc)
                accent = RGBA(0x0169cc)
                diffAdded = RGBA(0x00a240)
                diffRemoved = RGBA(0xe02e2a)
                skill = RGBA(0xb06dff)
                contrast = 0.60
            case (.codex, false):
                surface = RGBA(0xffffff)
                ink = RGBA(0x0d0d0d)
                accent = RGBA(0x0169cc)
                diffAdded = RGBA(0x00a240)
                diffRemoved = RGBA(0xe02e2a)
                skill = RGBA(0x751ed9)
                contrast = 0.45
            case (.linear, true):
                surface = RGBA(0x0f0f11)
                ink = RGBA(0xe3e4e6)
                accent = RGBA(0x606acc)
                diffAdded = RGBA(0x69c967)
                diffRemoved = RGBA(0xff7e78)
                skill = RGBA(0xc2a1ff)
                contrast = 0.60
            case (.linear, false):
                surface = RGBA(0xfcfcfd)
                ink = RGBA(0x1b1b1b)
                accent = RGBA(0x5e6ad2)
                diffAdded = RGBA(0x52a450)
                diffRemoved = RGBA(0xc94446)
                skill = RGBA(0x8160d8)
                contrast = 0.45
            }

            let strongChromeAmount = (isDark ? 0.075 : 0.055) * (contrast / 0.45)
            let subtleAccent = surface.mixed(with: accent, amount: isDark ? 0.20 : 0.11)

            return Palette(
                window: surface,
                titlebar: surface.mixed(with: ink, amount: strongChromeAmount),
                toolHeader: surface,
                toolHeaderInactive: surface,
                sidebar: surface,
                editor: surface,
                raised: surface.mixed(with: ink, amount: isDark ? 0.085 : 0.018),
                notification: surface.mixed(with: ink, amount: isDark ? 0.085 : 0.018),
                selection: accent,
                subtleSelection: subtleAccent,
                hoverBackground: ink.withAlpha(isDark ? 0.065 : 0.055),
                pressedBackground: ink.withAlpha(isDark ? 0.11 : 0.095),
                activeTabBackground: surface.mixed(with: ink, amount: isDark ? 0.075 : 0.012),
                tabUnderline: accent,
                diffInformationBackground: surface.mixed(with: accent, amount: isDark ? 0.18 : 0.10),
                diffInformationText: accent,
                divider: ink.withAlpha(isDark ? 0.10 : 0.12),
                panelBorder: ink.withAlpha(isDark ? 0.16 : 0.16),
                inputBackground: isDark
                    ? surface.mixed(with: RGBA(0x000000), amount: 0.15)
                    : surface,
                inputBorder: ink.withAlpha(isDark ? 0.15 : 0.18),
                inputFocusBorder: accent.withAlpha(0.90),
                popupBackground: surface.mixed(with: ink, amount: isDark ? 0.065 : 0.008),
                popupShadow: RGBA(0x000000, alpha: isDark ? 0.55 : 0.20),
                badgeBackground: ink.withAlpha(isDark ? 0.12 : 0.08),
                primaryText: ink,
                secondaryText: ink.withAlpha(isDark ? 0.62 : 0.60),
                tertiaryText: ink.withAlpha(isDark ? 0.43 : 0.42),
                toolWindowText: ink,
                toolWindowButtonText: ink.withAlpha(isDark ? 0.62 : 0.60),
                toolWindowSelectedText: RGBA(0xffffff),
                accent: accent,
                runAction: isDark ? RGBA(0x59a869) : RGBA(0x2e7d32),
                success: diffAdded,
                warning: isDark ? RGBA(0xe6a23c) : RGBA(0xa96500),
                error: diffRemoved,
                skill: skill,
                link: accent,
                guide: ink.withAlpha(isDark ? 0.10 : 0.11),
                activeGuide: ink.withAlpha(isDark ? 0.26 : 0.27)
            )
        }

        private static func lithe(isDark: Bool) -> Palette {
            typealias Components = (CGFloat, CGFloat, CGFloat, CGFloat)
            func adaptive(light: Components, dark: Components) -> RGBA {
                let value = isDark ? dark : light
                return RGBA(red: value.0, green: value.1, blue: value.2, alpha: value.3)
            }
            let secondaryText = adaptive(light: (0.373, 0.396, 0.439, 1), dark: (1, 1, 1, 0.50))

            return Palette(
                window: adaptive(light: (0.933, 0.945, 0.961, 1), dark: (0.157, 0.161, 0.173, 1)),
                titlebar: adaptive(light: (0.910, 0.922, 0.937, 1), dark: (0.157, 0.161, 0.173, 1)),
                toolHeader: adaptive(light: (0.984, 0.984, 0.988, 1), dark: (0.094, 0.098, 0.106, 1)),
                toolHeaderInactive: adaptive(light: (0.969, 0.973, 0.980, 1), dark: (0.094, 0.098, 0.106, 1)),
                sidebar: adaptive(light: (1, 1, 1, 1), dark: (0.094, 0.098, 0.106, 1)),
                editor: adaptive(light: (1, 1, 1, 1), dark: (0.094, 0.098, 0.106, 1)),
                raised: adaptive(light: (0.969, 0.973, 0.980, 1), dark: (0.165, 0.175, 0.190, 1)),
                notification: adaptive(light: (1, 1, 1, 1), dark: (51.0 / 255.0, 54.0 / 255.0, 59.0 / 255.0, 1)),
                selection: adaptive(light: (0.208, 0.455, 0.941, 1), dark: (0.208, 0.455, 0.941, 1)),
                subtleSelection: adaptive(light: (0.914, 0.922, 0.937, 1), dark: (0.205, 0.218, 0.238, 1)),
                hoverBackground: adaptive(light: (0.949, 0.953, 0.961, 1), dark: (1, 1, 1, 23.0 / 255.0)),
                pressedBackground: adaptive(light: (0.882, 0.890, 0.906, 1), dark: (1, 1, 1, 0.095)),
                activeTabBackground: adaptive(light: (1, 1, 1, 1), dark: (0.094, 0.098, 0.106, 1)),
                tabUnderline: adaptive(light: (0.208, 0.455, 0.941, 1), dark: (0.208, 0.455, 0.941, 1)),
                diffInformationBackground: adaptive(light: (0.910, 0.949, 1, 1), dark: (0.13, 0.20, 0.30, 1)),
                diffInformationText: adaptive(light: (0.141, 0.357, 0.620, 1), dark: (0.50, 0.72, 0.98, 1)),
                divider: adaptive(light: (0.847, 0.855, 0.875, 1), dark: (0.180, 0.188, 0.212, 1)),
                panelBorder: adaptive(light: (0.788, 0.800, 0.824, 1), dark: (0.263, 0.271, 0.290, 1)),
                inputBackground: adaptive(light: (1, 1, 1, 1), dark: (0.065, 0.070, 0.078, 1)),
                inputBorder: adaptive(light: (0.788, 0.800, 0.824, 1), dark: (1, 1, 1, 0.12)),
                inputFocusBorder: adaptive(light: (0.208, 0.455, 0.941, 0.90), dark: (0.208, 0.455, 0.941, 0.85)),
                popupBackground: adaptive(light: (1, 1, 1, 1), dark: (0.157, 0.161, 0.173, 1)),
                popupShadow: adaptive(light: (0, 0, 0, 0.16), dark: (0, 0, 0, 0.55)),
                badgeBackground: adaptive(light: (0.910, 0.918, 0.929, 1), dark: (1, 1, 1, 0.10)),
                primaryText: adaptive(light: (0.122, 0.137, 0.161, 1), dark: (0.875, 0.882, 0.898, 1)),
                secondaryText: secondaryText,
                tertiaryText: adaptive(light: (0.506, 0.533, 0.580, 1), dark: (1, 1, 1, 0.34)),
                toolWindowText: adaptive(light: (0.255, 0.275, 0.314, 1), dark: (0.875, 0.882, 0.898, 1)),
                toolWindowButtonText: isDark ? RGBA(0x9DA0A8) : secondaryText,
                toolWindowSelectedText: adaptive(light: (1, 1, 1, 1), dark: (1, 1, 1, 1)),
                accent: adaptive(light: (0.208, 0.455, 0.941, 1), dark: (0.208, 0.455, 0.941, 1)),
                runAction: adaptive(light: (0.180, 0.490, 0.196, 1), dark: (0.349, 0.659, 0.412, 1)),
                success: adaptive(light: (0.105, 0.545, 0.235, 1), dark: (0.28, 0.72, 0.39, 1)),
                warning: adaptive(light: (0.690, 0.410, 0.035, 1), dark: (0.91, 0.63, 0.20, 1)),
                error: adaptive(light: (0.780, 0.175, 0.175, 1), dark: (0.92, 0.33, 0.33, 1)),
                skill: adaptive(light: (0.55, 0.18, 0.64, 1), dark: (0.80, 0.48, 0.77, 1)),
                link: adaptive(light: (0.102, 0.361, 0.722, 1), dark: (0.42, 0.68, 1.00, 1)),
                guide: adaptive(light: (0.902, 0.910, 0.922, 1), dark: (1, 1, 1, 0.085)),
                activeGuide: adaptive(light: (0.682, 0.706, 0.745, 1), dark: (1, 1, 1, 0.24))
            )
        }
    }

    static var activeTheme: AppColorTheme { AppThemeRuntime.shared.activeTheme }

    enum ResolvedColorToken {
        case titlebar
        case editor
        case sidebar
        case toolHeader
        case popupBackground
        case primaryText
        case secondaryText
        case accent
        case link
        case success
        case warning
        case error
        case skill
        case guide
        case activeGuide
        case divider
    }

    static func nsColor(
        _ token: ResolvedColorToken,
        theme: AppColorTheme = activeTheme,
        isDark: Bool
    ) -> NSColor {
        let palette = Palette.make(theme: theme, isDark: isDark)
        return switch token {
        case .titlebar: palette.titlebar.nsColor
        case .editor: palette.editor.nsColor
        case .sidebar: palette.sidebar.nsColor
        case .toolHeader: palette.toolHeader.nsColor
        case .popupBackground: palette.popupBackground.nsColor
        case .primaryText: palette.primaryText.nsColor
        case .secondaryText: palette.secondaryText.nsColor
        case .accent: palette.accent.nsColor
        case .link: palette.link.nsColor
        case .success: palette.success.nsColor
        case .warning: palette.warning.nsColor
        case .error: palette.error.nsColor
        case .skill: palette.skill.nsColor
        case .guide: palette.guide.nsColor
        case .activeGuide: palette.activeGuide.nsColor
        case .divider: palette.divider.nsColor
        }
    }

    // MARK: - 背景层次
    static var window: Color { adaptive(\.window) }
    static var titlebar: Color { adaptive(\.titlebar) }
    // IntelliJ Community Islands theme tokens: platform/platform-resources/src/themes/islands/ManyIslands{Dark,Light}.theme.json.
    static var settingsSurface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            settingsSurfaceNSColor(for: appearance)
        })
    }
    static func settingsSurfaceNSColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return nsColor(.sidebar, isDark: isDark)
    }
    static let settingsControlAccent = Color(
        red: 56.0 / 255.0,
        green: 113.0 / 255.0,
        blue: 225.0 / 255.0
    )
    static var settingsPrimaryAction: Color { settingsControlAccent }
    static var settingsListSurface: Color { settingsSurface }
    static var settingsFont: Font { .custom("Inter-Regular", size: 13) }
    static var settingsStrongFont: Font { .custom("Inter-SemiBold", size: 13) }
    static var settingsSearchBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 78.0 / 255, green: 81.0 / 255, blue: 87.0 / 255, alpha: 1)
                : NSColor(srgbRed: 201.0 / 255, green: 204.0 / 255, blue: 214.0 / 255, alpha: 1)
        })
    }
    static var settingsSelection: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 42.0 / 255.0, green: 67.0 / 255.0, blue: 113.0 / 255.0, alpha: 1)
                : NSColor(srgbRed: 208.0 / 255.0, green: 223.0 / 255.0, blue: 254.0 / 255.0, alpha: 1)
        })
    }
    static var settingsSelectionText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .white : .black
        })
    }
    static var settingsControlBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 43.0 / 255.0, green: 45.0 / 255.0, blue: 48.0 / 255.0, alpha: 1)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        })
    }
    static var settingsTextFieldBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? settingsSurfaceNSColor(for: appearance) : .white
        })
    }
    static var settingsControlBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 64.0 / 255.0, green: 67.0 / 255.0, blue: 74.0 / 255.0, alpha: 1)
                : NSColor(srgbRed: 209.0 / 255.0, green: 211.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
        })
    }
    static var settingsPopupBackground: Color { settingsControlBackground }
    static var settingsPopupBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 76.0 / 255.0, green: 79.0 / 255.0, blue: 86.0 / 255.0, alpha: 1)
                : NSColor(srgbRed: 233.0 / 255.0, green: 234.0 / 255.0, blue: 238.0 / 255.0, alpha: 1)
        })
    }
    static var settingsSelectBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 57.0 / 255, green: 59.0 / 255, blue: 64.0 / 255, alpha: 1)
                : .white
        })
    }
    static var toolHeader: Color { adaptive(\.toolHeader) }
    static var toolHeaderInactive: Color { adaptive(\.toolHeaderInactive) }
    static var sidebar: Color { adaptive(\.sidebar) }
    static var editor: Color { adaptive(\.editor) }
    static var raised: Color { adaptive(\.raised) }
    static var notificationBackground: Color { adaptive(\.notification) }
    static var contextMenuBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if activeTheme == .lithe, isDark {
                return NSColor(srgbRed: 38.0 / 255.0, green: 39.0 / 255.0, blue: 44.0 / 255.0, alpha: 1)
            }
            return Palette.make(theme: activeTheme, isDark: isDark).popupBackground.nsColor
        })
    }

    // MARK: - 选中与悬停
    static var selection: Color { adaptive(\.selection) }
    static var subtleSelection: Color { adaptive(\.subtleSelection) }
    static var hoverBackground: Color { adaptive(\.hoverBackground) }
    static var pressedBackground: Color { adaptive(\.pressedBackground) }

    // MARK: - 标签页
    static var activeTabBackground: Color { adaptive(\.activeTabBackground) }
    static let inactiveTabBackground = Color.clear
    static var tabUnderline: Color { adaptive(\.tabUnderline) }
    static var diffInformationBackground: Color { adaptive(\.diffInformationBackground) }
    static var diffInformationText: Color { adaptive(\.diffInformationText) }

    // MARK: - 分隔与边框
    static var divider: Color { adaptive(\.divider) }
    static var panelBorder: Color { adaptive(\.panelBorder) }

    // MARK: - 输入控件
    static var inputBackground: Color { adaptive(\.inputBackground) }
    static var inputBorder: Color { adaptive(\.inputBorder) }
    static var inputFocusBorder: Color { adaptive(\.inputFocusBorder) }
    // Islands' control-bg/control-border/text-secondary/control-brand-border.
    static var searchFieldBackground: Color {
        activeTheme == .lithe ? searchFieldColor(light: 0xFFFFFF, dark: 0x191A1C) : inputBackground
    }
    static var searchFieldBorder: Color {
        activeTheme == .lithe ? searchFieldColor(light: 0xD1D3D9, dark: 0x40434A) : inputBorder
    }
    static var searchFieldFocusBorder: Color {
        activeTheme == .lithe ? searchFieldColor(light: 0x3871E1, dark: 0x3871E1) : inputFocusBorder
    }
    static var searchFieldPlaceholder: Color {
        activeTheme == .lithe ? searchFieldColor(light: 0x73767C, dark: 0x73767C) : secondaryText
    }
    static var searchFieldText: Color {
        activeTheme == .lithe ? searchFieldColor(light: 0x000000, dark: 0xD1D3D9) : primaryText
    }
    private static func searchFieldColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            RGBA(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light).nsColor
        })
    }

    // MARK: - 浮层
    static var popupBackground: Color { adaptive(\.popupBackground) }
    static var popupShadow: Color { adaptive(\.popupShadow) }
    static var badgeBackground: Color { adaptive(\.badgeBackground) }

    // MARK: - 文本
    static var primaryText: Color { adaptive(\.primaryText) }
    static var secondaryText: Color { adaptive(\.secondaryText) }
    static var tertiaryText: Color { adaptive(\.tertiaryText) }
    static var toolWindowText: Color { adaptive(\.toolWindowText) }
    static var toolWindowButtonText: Color { adaptive(\.toolWindowButtonText) }
    static var toolWindowSelectedText: Color { adaptive(\.toolWindowSelectedText) }

    // MARK: - 语义色
    static var accent: Color { adaptive(\.accent) }
    static var runAction: Color { adaptive(\.runAction) }
    static var success: Color { adaptive(\.success) }
    static var warning: Color { adaptive(\.warning) }
    static var error: Color { adaptive(\.error) }
    static var skill: Color { adaptive(\.skill) }
    /// Cmd/Ctrl 悬停时标识符转成的“可点击”色。
    static var link: Color { adaptive(\.link) }
    // 语义化别名，便于 AppKit 装饰代码与设计稿 token 同名。
    static var linkColor: Color { link }

    // MARK: - 编辑器缩进竖线
    static var guide: Color { adaptive(\.guide) }
    static var activeGuide: Color { adaptive(\.activeGuide) }
    static var guideColor: Color { guide }
    static var activeGuideColor: Color { activeGuide }

    private static func adaptive(_ keyPath: KeyPath<Palette, RGBA>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let palette = Palette.make(theme: activeTheme, isDark: isDark)
            return palette[keyPath: keyPath].nsColor
        })
    }

    static var uiFont: Font { uiFont(size: 14) }
    static var smallFont: Font { uiFont(size: 12) }
    static let codeFont = Font.custom("JetBrainsMono-Regular", size: 13)
    static let editorLineHeightMultiple: CGFloat = 1.2
    static let editorBaselineLift: CGFloat = 1.5

    static func editorFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let postScriptName = weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? "JetBrainsMono-Bold"
            : "JetBrainsMono-Regular"
        return NSFont(name: postScriptName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static var editorParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = editorLineHeightMultiple
        return style
    }

    private static func uiFont(size: CGFloat) -> Font {
        if activeTheme != .lithe, NSFont(name: "Inter", size: size) != nil {
            return Font.custom("Inter", size: size)
        }
        return Font.system(size: size, weight: .regular)
    }

    /// 统一的尺寸与间距刻度，避免各视图各写一套魔法数字。
    enum Metrics {
        static let rowHeight: CGFloat = 24
        static let toolbarIconSize: CGFloat = 16
        static let toolbarIconButtonSize: CGFloat = 22
        static let treeRowHeight: CGFloat = 27
        // IntelliJ IDEA New UI uses contiguous project-tree rows, 4/12 pt
        // tree insets, and an 8 pt selection arc (4 pt corner radius).
        static let projectTreeRowSpacing: CGFloat = 0
        static let projectTreeContentVerticalInset: CGFloat = 4
        static let projectTreeContentHorizontalInset: CGFloat = 12
        static let projectTreeSelectionCornerRadius: CGFloat = 4
        static let treeIconSize: CGFloat = 16
        static let treeFontSize: CGFloat = 13.5
        static let tabHeight: CGFloat = 34
        static let toolbarHeight: CGFloat = 40
        static let toolWindowHeaderHeight: CGFloat = 30
        static let statusBarHeight: CGFloat = 24
        static let cornerRadius: CGFloat = 5
        static let popupCornerRadius: CGFloat = 10
        static let contextMenuCornerRadius: CGFloat = 9
        static let controlCornerRadius: CGFloat = 6
    }

    /// Commit tool-window values shared by the Changes sidebar and editor.
    enum Commit {
        static let toolbarHeight = Metrics.toolbarHeight
        static let listMinimumHeight: CGFloat = 120
        static let areaMinimumHeight: CGFloat = 124
        static let panelPadding: CGFloat = 10
        static let toolbarFontSize: CGFloat = 12.5
        static let tabItemHorizontalPadding: CGFloat = 12
        static let metadataFontSize: CGFloat = 12
        static let amendFontSize: CGFloat = 12.5
        static let actionIconSize: CGFloat = 14
        static let messageFontSize: CGFloat = 13
        static let editorHorizontalInset: CGFloat = 8
        static let editorVerticalInset: CGFloat = 7
        static let compactButtonHeight: CGFloat = 24
        static let compactButtonPadding: CGFloat = 7
        static let compactButtonFontSize: CGFloat = 11
    }
}

extension View {
    func litheToolbarIconButton(isEnabled: Bool = true) -> some View {
        buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize))
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
    }

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
        animation: Animation? = nil
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
    var size: CGFloat = 28
    var cornerRadius: CGFloat = LitheTheme.Metrics.cornerRadius
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(LitheTheme.toolWindowText)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        configuration.isPressed && isEnabled
                            ? LitheTheme.pressedBackground
                            : (isEnabled && isHovering ? LitheTheme.hoverBackground : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Keeps borderless button labels at full opacity while pressed.
struct LitheNoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == LitheNoPressButtonStyle {
    static var litheNoPress: LitheNoPressButtonStyle { .init() }
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
    var backgroundColor = LitheTheme.accent
    var restingOpacity = 0.92
    var horizontalPadding: CGFloat = 18
    var height: CGFloat = 30
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(backgroundColor.opacity(configuration.isPressed ? 0.78 : (isHovering ? 1 : restingOpacity)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }
}

struct LitheSecondaryButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 18
    var height: CGFloat = 30
    var fontSize: CGFloat = 13
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(configuration.isPressed ? LitheTheme.subtleSelection : (isHovering ? LitheTheme.raised : LitheTheme.raised.opacity(0.72)))
            )
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .strokeBorder(LitheTheme.panelBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .lithePointer()
    }
}

private struct LithePointingHandCursorKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var lithePointingHandCursorEnabled: Bool {
        get { self[LithePointingHandCursorKey.self] }
        set { self[LithePointingHandCursorKey.self] = newValue }
    }
}

private struct LithePointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lithePointingHandCursorEnabled) private var pointingHandCursorEnabled
    @State private var cursor = LithePointerCursor()

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                cursor.isHovered = isInside
                cursor.update(isPointing: isInside && isEnabled && pointingHandCursorEnabled)
            }
            .onChange(of: isEnabled) { _ in
                cursor.update(isPointing: cursor.isHovered && isEnabled && pointingHandCursorEnabled)
            }
            .onChange(of: pointingHandCursorEnabled) { _ in
                cursor.update(isPointing: cursor.isHovered && isEnabled && pointingHandCursorEnabled)
            }
            .onDisappear {
                cursor.isHovered = false
                cursor.update(isPointing: false)
            }
    }
}

/// Hover tracking lives in a reference box rather than `@State` because nothing
/// in the view body depends on it. Storing it as view state would invalidate
/// every hovered control, which is costly when the pointer sweeps across many
/// rows during a scroll.
private final class LithePointerCursor {
    var isHovered = false
    private var isPointing = false

    /// The push/pop pair is balanced even when a view disappears.
    @MainActor
    func update(isPointing newValue: Bool) {
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

/// Shared search chrome follows IDEA SearchFieldWithExtension + DarculaSearchFieldWithExtensionBorder:
/// 28pt text, 1pt content insets and 3pt border insets; focus expands outward by 1pt.
/// Source: IntelliJ Community c7f91397, Component.arc=8 (a 4pt radius), LW=1, BW=2.
struct LitheSearchFieldStyle: ViewModifier {
    var isFocused: Bool

    // SearchTextField uses 15 columns; its UI measures 'm', adds margins and icon space.
    static let preferredWidth = ceil(("m" as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: 13)
    ]).width) * 15 + 10 + 10 + 16 + 2 + 16 + 3

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .circular)
        let borderColor = isFocused ? LitheTheme.searchFieldFocusBorder : LitheTheme.searchFieldBorder
        content
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(LitheTheme.searchFieldText)
            // The wrapper removes the inner text border: default margins are
            // 6pt, plus 1pt content padding and the outer 3pt border insets.
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                shape.fill(LitheTheme.searchFieldBackground)
                    .padding(3.5)
            )
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
                    .padding(isFocused ? 2 : 3)
            }
    }
}

extension View {
    func litheSearchField(isFocused: Bool = false) -> some View {
        modifier(LitheSearchFieldStyle(isFocused: isFocused))
    }

    /// Paints rounded control chrome without clipping AppKit-backed content.
    ///
    /// SwiftUI represents controls such as `TextEditor`, `TextField`, and the
    /// macOS checkbox with native AppKit views. Applying a mask or clip to one
    /// of their ancestors can replace those views with the yellow unavailable
    /// placeholder. Keep rounding in the background and border layers instead.
    func litheRoundedControlBackground(
        _ color: Color,
        cornerRadius: CGFloat = LitheTheme.Metrics.controlCornerRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(color)
        }
    }

    func litheContextMenuSurface(
        cornerRadius: CGFloat = LitheTheme.Metrics.contextMenuCornerRadius
    ) -> some View {
        self
            .litheRoundedControlBackground(
                LitheTheme.contextMenuBackground,
                cornerRadius: cornerRadius
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(LitheTheme.panelBorder, lineWidth: 1)
            }
    }

    /// 浮层统一外观：圆角、背景、1pt 边框和投影。
    func lithePopupChrome(cornerRadius: CGFloat = LitheTheme.Metrics.popupCornerRadius) -> some View {
        self
            .litheRoundedControlBackground(
                LitheTheme.popupBackground,
                cornerRadius: cornerRadius
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(LitheTheme.panelBorder, lineWidth: 1)
            }
            .shadow(color: LitheTheme.popupShadow, radius: 30, y: 14)
    }
}
