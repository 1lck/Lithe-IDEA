import Foundation
import SwiftUI

/// Per-repository accent colors for the Git Log reference pane.
///
/// IntelliJ IDEA marks every repository in the log's reference tree with a
/// colored dot. Lithe mirrors that: the repository group header gets a dot and
/// each reference row gets a thin leading bar. A color is assigned by the
/// repository's position in the workspace's *full*, ordered repository list, so
/// hiding worktrees never recolors the repositories that stay visible.
enum GitRepositoryColor {
    /// Eight hues chosen to stay legible on both light and dark backgrounds.
    static let paletteHex = [
        "#55d68b", "#65a9ff", "#d77eea", "#f3aa59",
        "#e76c72", "#56c7cf", "#b08cff", "#ffd166"
    ]

    static func color(at index: Int) -> Color {
        Color(hex: paletteHex[((index % paletteHex.count) + paletteHex.count) % paletteHex.count])
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
