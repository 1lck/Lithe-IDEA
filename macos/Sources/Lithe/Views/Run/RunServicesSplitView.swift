import SwiftUI

/// Keeps both resize states inside the existing split containers. Persisted
/// widths change only on commit, so pointer events do not rebuild RunView.
struct RunServicesSplitView<Scopes: View, Configurations: View, Content: View>: View {
    let isScopeCollapsed: Bool
    let scopes: Scopes
    let configurations: Configurations
    let content: Content

    @AppStorage("lithe.run.scopeListWidth") private var scopeWidth = 170.0
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

    @ViewBuilder
    private func panes(width: CGFloat) -> some View {
        if isScopeCollapsed {
            HStack(spacing: 0) {
                scopes.frame(width: RunServicesLayout.collapsedScopeWidth)
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                configurationSplit
            }
        } else {
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: CGFloat(scopeWidth),
                minimum: RunServicesLayout.scopeMinimum,
                maximum: RunServicesLayout.scopeMaximum(in: width),
                flexibleMinimum: RunServicesLayout.configurationMinimum
                    + SplitHandleView.thickness + RunServicesLayout.outputMinimum,
                onCommit: { scopeWidth = Double($0) },
                sized: { scopes },
                flexible: { configurationSplit }
            )
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
                onCommit: { configurationWidth = Double($0) },
                sized: { configurations },
                flexible: { content }
            )
        }
    }
}

enum RunServicesLayout {
    static let scopeMinimum: CGFloat = 140
    static let configurationMinimum: CGFloat = 240
    static let outputMinimum: CGFloat = 320
    static let collapsedScopeWidth: CGFloat = 32

    static func minimumWidth(isScopeCollapsed: Bool) -> CGFloat {
        (isScopeCollapsed ? collapsedScopeWidth + 1 : scopeMinimum + SplitHandleView.thickness)
            + configurationMinimum + SplitHandleView.thickness + outputMinimum
    }

    static func scopeMaximum(in width: CGFloat) -> CGFloat {
        max(scopeMinimum, min(280, width - configurationMinimum - outputMinimum - 2 * SplitHandleView.thickness))
    }

    static func configurationMaximum(in width: CGFloat) -> CGFloat {
        max(configurationMinimum, min(480, width - outputMinimum - SplitHandleView.thickness))
    }
}
