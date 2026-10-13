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
    private func roots(_ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/workspace/repo-\($0)") }
    }

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

    @Test
    func colorForRootMatchesItsSlot() throws {
        let repositoryRoots = roots(3)
        for (slot, root) in repositoryRoots.enumerated() {
            let resolved = try #require(
                NSColor(GitRepositoryColor.color(for: root, in: repositoryRoots)).usingColorSpace(.sRGB)
            )
            let expected = try #require(NSColor(GitRepositoryColor.color(at: slot)).usingColorSpace(.sRGB))
            #expect(resolved == expected)
        }
    }

    @Test
    func repositoriesReceiveDistinctSlotsInListOrder() {
        let repositoryRoots = roots(8)
        let slots = repositoryRoots.map {
            GitRepositoryColor.index(for: $0, in: repositoryRoots)
        }
        #expect(slots == Array(0..<8))
    }

    @Test
    func slotIsStableWhenTheVisibleSubsetChanges() {
        let all = roots(3)
        // Hiding the middle repository (for example a worktree) must not shift
        // the third repository onto the second slot. Assignment always reads the
        // full ordered list, so `repo-2` keeps slot 2.
        #expect(GitRepositoryColor.index(for: all[2], in: all) == 2)
        #expect(GitRepositoryColor.index(for: all[2], in: [all[0], all[2]]) == 1)
    }

    @Test
    func slotsWrapAfterThePaletteSize() {
        let repositoryRoots = roots(9)
        #expect(GitRepositoryColor.index(for: repositoryRoots[8], in: repositoryRoots) == 0)
    }

    @Test
    func singleRepositoryWorkspaceShowsNoColor() {
        #expect(!GitRepositoryColor.isVisible(for: roots(1)))
        #expect(GitRepositoryColor.isVisible(for: roots(2)))
        // The fallback color still resolves, so a caller that ignores visibility
        // cannot crash; it simply gets the first palette entry.
        #expect(GitRepositoryColor.index(for: roots(1)[0], in: roots(1)) == 0)
    }

    @Test
    func unknownRootFallsBackToTheFirstColor() {
        let repositoryRoots = roots(3)
        let outsider = URL(fileURLWithPath: "/elsewhere/other")
        #expect(GitRepositoryColor.index(for: outsider, in: repositoryRoots) == 0)
    }
}
