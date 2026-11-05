import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithe

/// The Git Log marks each repository with a color. The color must stay with a
/// repository when worktrees are hidden, or the pane would recolor itself on a
/// toggle and mislead the user about which repository a row belongs to.
@Suite("Git repository colors")
struct GitRepositoryColorTests {
    @Test
    func paletteProvidesEightDistinctColors() {
        #expect(GitRepositoryColor.paletteHex.count == 8)
        #expect(Set(GitRepositoryColor.paletteHex).count == 8)
    }

    @Test
    func resolvedPaletteColorsAreDistinctAndOpaque() throws {
        let colors = try (0..<8).map { index in
            try #require(NSColor(GitRepositoryColor.color(at: index)).usingColorSpace(.sRGB))
        }
        for color in colors {
            #expect(color.alphaComponent == 1)
        }
        for outer in colors.indices {
            for inner in colors.indices where inner > outer {
                #expect(colors[outer] != colors[inner])
            }
        }
    }

}
