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

    /// A workspace with a single repository has nothing to disambiguate, so the
    /// pane stays exactly as it was before this feature.
    static func isVisible(for availableRepositoryRoots: [URL]) -> Bool {
        availableRepositoryRoots.count > 1
    }

    /// The palette index for `repositoryRoot`, matched by standardized path
    /// against the full ordered list. Unknown roots fall back to index 0.
    static func index(for repositoryRoot: URL, in availableRepositoryRoots: [URL]) -> Int {
        let target = repositoryRoot.standardizedFileURL.path
        guard let position = availableRepositoryRoots.firstIndex(where: {
            $0.standardizedFileURL.path == target
        }) else { return 0 }
        return position % paletteHex.count
    }

    static func color(for repositoryRoot: URL, in availableRepositoryRoots: [URL]) -> Color {
        color(at: index(for: repositoryRoot, in: availableRepositoryRoots))
    }

    static func color(at index: Int) -> Color {
        Color(hex: paletteHex[((index % paletteHex.count) + paletteHex.count) % paletteHex.count])
    }
}
