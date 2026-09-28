import AppKit
import SwiftUI

/// IDEA Community Islands theme overrides for recent-project avatars and headers.
struct ProjectIdentityAppearance {
    private typealias Colors = (avatarStart: UInt32, avatarEnd: UInt32, darkToolbar: UInt32, lightToolbar: UInt32)

    private static let palette: [Colors] = [
        (0xE08855, 0xE9806F, 0x664832, 0xF5D4C1),
        (0xB08B14, 0xBB7F19, 0x5E4724, 0xEEE2BD),
        (0xA1A359, 0x87AA59, 0x45522F, 0xDBE7C9),
        (0x3B92B8, 0x6183EC, 0x335661, 0xCADFEA),
        (0x3574F0, 0x7A64F0, 0x394773, 0xDBD8EF),
        (0xC84D8F, 0xA956CF, 0x613861, 0xEED7F5),
        (0x955AE0, 0xA84DE0, 0x503D70, 0xDFCCF4),
        (0x24A394, 0x279CCD, 0x325959, 0xBEE4E1),
        (0x5FAD65, 0x3D968B, 0x365439, 0xCCEBD1)
    ]

    let avatarStart: Color
    let avatarEnd: Color
    let toolbarColor: Color

    init(colorIndex: Int, isDark: Bool) {
        let colors = Self.palette[Self.validColorIndex(colorIndex)]
        avatarStart = Self.color(colors.avatarStart)
        avatarEnd = Self.color(colors.avatarEnd)
        toolbarColor = Self.color(isDark ? colors.darkToolbar : colors.lightToolbar)
    }

    static func colorIndex(for projectURL: URL?) -> Int {
        guard let path = projectURL?.standardizedFileURL.path else { return 0 }
        // ponytail: A stable path hash avoids a second project-color store, but cannot retain a
        // user-chosen color. Add project-owned metadata when color customization is supported.
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(palette.count))
    }

    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let characters = words.prefix(2).compactMap(\.first)
        return characters.isEmpty ? "LI" : String(characters).uppercased()
    }

    var avatarGradient: LinearGradient {
        LinearGradient(colors: [avatarStart, avatarEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func toolbarGlow(over background: Color) -> Color {
        // IDEA's generated project colors are opaque; its frame painter blends
        // them into the header at 85% (custom colors have a lower alpha).
        return Self.blend(background, with: toolbarColor, fraction: 0.85)
    }

    static func blend(_ background: Color, with foreground: Color, fraction: CGFloat) -> Color {
        guard let base = NSColor(background).usingColorSpace(.sRGB),
              let color = NSColor(foreground).usingColorSpace(.sRGB) else { return background }
        let amount = min(max(fraction, 0), 1)
        return Color(
            .sRGB,
            red: Double(base.redComponent + (color.redComponent - base.redComponent) * amount),
            green: Double(base.greenComponent + (color.greenComponent - base.greenComponent) * amount),
            blue: Double(base.blueComponent + (color.blueComponent - base.blueComponent) * amount),
            opacity: 1
        )
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    private static func validColorIndex(_ index: Int) -> Int {
        palette.indices.contains(index) ? index : 0
    }
}

struct ProjectAvatarBadge: View {
    let name: String
    let colorIndex: Int
    let size: CGFloat
    var isEnabled = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let appearance = ProjectIdentityAppearance(colorIndex: colorIndex, isDark: colorScheme == .dark)
        Text(ProjectIdentityAppearance.initials(for: name))
            .font(.system(size: max(10, size * 0.35), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if isEnabled {
                    appearance.avatarGradient
                } else {
                    LitheTheme.raised
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
    }
}
