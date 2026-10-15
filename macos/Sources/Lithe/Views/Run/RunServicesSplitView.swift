import SwiftUI

/// The scope icons use a fixed action stripe. The configuration splitter keeps
/// its local drag state and persists the width only when the drag completes.
struct RunServicesSplitView<Scopes: View, Configurations: View, Content: View>: View {
    let isScopeCollapsed: Bool
    let scopes: Scopes
    let configurations: Configurations
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("lithe.run.configurationListWidth") private var configurationWidth = 280.0

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, minimumWidth)
            if geometry.size.width < minimumWidth {
                // Narrow docked windows retain usable columns with horizontal
                // navigation instead of negative sizes or overlapping controls.
                ScrollView(.horizontal) {
                    panes(width: width)
                        .frame(width: width, height: geometry.size.height)
                }
            } else {
                panes(width: width)
            }
        }
    }

    private var minimumWidth: CGFloat {
        RunServicesLayout.minimumWidth(isScopeCollapsed: isScopeCollapsed)
    }

    private func panes(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            scopes.frame(width: isScopeCollapsed ? RunServicesLayout.collapsedScopeWidth : RunServicesLayout.scopeMinimum)
            Rectangle().fill(LitheTheme.toolWindowBorder(for: colorScheme))
                .frame(width: 1)
                .frame(width: isScopeCollapsed ? 1 : SplitHandleView.thickness)
            configurationSplit
        }
    }

    private var configurationSplit: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: CGFloat(configurationWidth),
                minimum: RunServicesLayout.configurationMinimum,
                maximum: RunServicesLayout.configurationMaximum(in: geometry.size.width),
                flexibleMinimum: RunServicesLayout.outputMinimum,
                dividerColor: LitheTheme.toolWindowBorder(for: colorScheme),
                onCommit: { configurationWidth = Double($0) },
                sized: { configurations },
                flexible: { content }
            )
        }
    }
}

enum RunServicesLayout {
    static let scopeMinimum: CGFloat = LitheTheme.ActionStripe.width
    static let configurationMinimum: CGFloat = 240
    static let outputMinimum: CGFloat = 320
    static let collapsedScopeWidth: CGFloat = 32

    static func minimumWidth(isScopeCollapsed: Bool) -> CGFloat {
        (isScopeCollapsed ? collapsedScopeWidth + 1 : scopeMinimum + SplitHandleView.thickness)
            + configurationMinimum + SplitHandleView.thickness + outputMinimum
    }

    static func scopeMaximum(in width: CGFloat) -> CGFloat {
        scopeMinimum
    }

    static func configurationMaximum(in width: CGFloat) -> CGFloat {
        max(configurationMinimum, min(480, width - outputMinimum - SplitHandleView.thickness))
    }
}
