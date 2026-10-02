import AppKit
import SwiftUI

/// Conversation-local colors mirror the reference without changing the workbench.
enum AgentPanelStyle {
    static let canvas = adaptive(dark: 0x1e1e1e, light: 0xffffff)
    static let header = adaptive(dark: 0x242424, light: 0xf5f5f5)
    static let context = adaptive(dark: 0x2f2f2f, light: 0xf0f0f0)
    static let toolbar = adaptive(dark: 0x1b1b1b, light: 0xf8f8f8)
    static let border = adaptive(dark: 0x303030, light: 0xdcdcdc)
    static let text = adaptive(dark: 0xcccccc, light: 0x333333)
    static let secondary = adaptive(dark: 0x888888, light: 0x666666)
    static let muted = adaptive(dark: 0x666666, light: 0x777777)
    static let logo = adaptive(dark: 0x555555, light: 0x777777)
    static let focus = adaptive(dark: 0x007fd4, light: 0x0078d4)
    static let selected = adaptive(dark: 0x094771, light: 0xcce7ff)
    static let versionText = adaptive(dark: 0xddd6fe, light: 0x6d28d9)
    static let versionAccent = Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)

    static func brandTint(for name: String?, isDark: Bool) -> UInt32? {
        switch name?.lowercased() {
        case "claude", "claude code": 0xd97757
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
        case "claude", "claude code": filename = "claude"
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

struct AgentToolbarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(AgentPanelStyle.secondary)
            .frame(width: 28, height: 28)
            .background(
                configuration.isPressed || isHovering ? AgentPanelStyle.context : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
