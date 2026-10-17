import AppKit
import SwiftUI

/// Conversation surfaces follow the same live theme tokens as the workbench.
enum AgentPanelStyle {
    // Product reading-column proportion; composer insets stay inside this column.
    static let editorContentWidthFraction: CGFloat = 0.8
    static let headerLeadingInset: CGFloat = 12
    static let iconLeadingInset = headerLeadingInset + LitheTheme.MainToolbar.comboInsets.leading
    static let iconButtonLeadingInset = iconLeadingInset
        - (LitheTheme.Metrics.toolbarIconButtonSize - LitheTheme.Metrics.toolbarIconSize) / 2
    static var canvas: Color { LitheTheme.editor }
    static var header: Color { LitheTheme.toolHeader }
    static var context: Color { LitheTheme.raised }
    static var toolbar: Color { LitheTheme.editor }
    static var border: Color { LitheTheme.panelBorder }
    static var text: Color { LitheTheme.primaryText }
    static var secondary: Color { LitheTheme.secondaryText }
    static var muted: Color { LitheTheme.tertiaryText }
    static var logo: Color { LitheTheme.tertiaryText }
    static var focus: Color { LitheTheme.inputFocusBorder }
    static let selected = adaptive(dark: 0x094771, light: 0xcce7ff)
    static let versionText = adaptive(dark: 0xddd6fe, light: 0x6d28d9)
    static let versionAccent = Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)

    static var welcomeGradient: LinearGradient {
        LinearGradient(colors: [context, LitheTheme.Welcome.bannerAccent],
                       startPoint: .leading, endPoint: .trailing)
    }

    static func brandTint(for name: String?, isDark: Bool) -> UInt32? {
        switch name?.lowercased() {
        case "claude", "claude code", "claude agent": 0xd97757
        case "codex": isDark ? 0xcccccc : 0x333333
        default: nil
        }
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: 1
            )
        })
    }
}

/// Reuse the vendor silhouettes; toolbar marks retain their color in native menus.
struct AgentBrandIcon: View {
    enum Style { case template, brand }

    let name: String?
    var size: CGFloat = 16
    var style: Style = .template
    @Environment(\.colorScheme) private var colorScheme

    private var tint: UInt32? {
        style == .brand ? AgentPanelStyle.brandTint(for: name, isDark: colorScheme == .dark) : nil
    }

    var body: some View {
        Group {
            if let image = AgentBrandIconLoader.image(name: name, size: size, tint: tint) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(tint == nil ? .template : .original)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum AgentBrandIconLoader {
    private struct CacheKey: Hashable {
        let bundleURL: URL
        let filename: String
        let size: Int
        let tint: UInt32?
    }
    private static var images: [CacheKey: NSImage] = [:]

    static func image(
        name: String?, size: CGFloat = 64,
        tint: UInt32? = nil,
        resourceBundle: Bundle? = resolveResourceBundle()
    ) -> NSImage? {
        let filename: String
        switch name?.lowercased() {
        case "codex": filename = "openai"
        case "claude", "claude code", "claude agent": filename = "claude"
        default: return nil
        }
        guard let resourceBundle else { return nil }
        let key = CacheKey(bundleURL: resourceBundle.bundleURL, filename: filename,
                           size: max(1, Int(size.rounded())), tint: tint)
        if let image = images[key] { return image }
        guard let url = resourceBundle.url(forResource: filename, withExtension: "svg", subdirectory: "AgentIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        // Native Menu labels read NSImage.size rather than the SwiftUI frame.
        image.size = NSSize(width: key.size, height: key.size)
        let rendered: NSImage
        if let tint {
            let color = NSColor(srgbRed: CGFloat((tint >> 16) & 255) / 255,
                                green: CGFloat((tint >> 8) & 255) / 255,
                                blue: CGFloat(tint & 255) / 255, alpha: 1)
            // SwiftUI foreground styles can be lost when Menu converts its label
            // to AppKit. Color the SVG's alpha mask in memory and keep it original.
            rendered = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            rendered.isTemplate = false
        } else {
            rendered = image
        }
        images[key] = rendered
        return rendered
    }

    nonisolated static func resolveResourceBundle(
        mainBundle: Bundle = .main,
        developmentBundle: () -> Bundle = { Bundle.module }
    ) -> Bundle? {
        // Packaged assets are read-only inputs. SwiftPM's generated accessor looks
        // beside the app or in the build tree, not in Contents/Resources.
        let packagedURL = mainBundle.resourceURL?
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        if let packagedURL, let bundle = Bundle(url: packagedURL) {
            return bundle
        }
        // A damaged installed app must use the fallback glyph, never the fatal
        // SwiftPM accessor or an unrelated development machine's build output.
        guard mainBundle.bundleURL.pathExtension != "app" else { return nil }
        let adjacentURL = mainBundle.bundleURL
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        return Bundle(url: adjacentURL) ?? developmentBundle()
    }
}
