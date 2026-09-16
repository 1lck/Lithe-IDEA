import SwiftUI
import LitheGitModule

/// Shared Monaco comparison for local history and branch comparisons.
struct DiffPaneView: View {
    let rows: [DiffRow]
    let fileExtension: String
    var minimumWidth: CGFloat = 900
    var highlightsWords: Bool = true
    var collapsesUnchangedRegions: Bool = true
    var showsDiffMap: Bool = true

    var body: some View {
        MonacoDiffEditor(rows: rows, fileExtension: fileExtension,
            highlightsWords: highlightsWords,
            collapsesUnchangedRegions: collapsesUnchangedRegions,
            showsDiffMap: showsDiffMap)
    }
}
