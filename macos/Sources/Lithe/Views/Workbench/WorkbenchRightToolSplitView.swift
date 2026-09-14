import SwiftUI

enum WorkbenchRightToolGeometry {
    // Reserve the project tree, editor, and their existing separator.
    static let minimumWorkspaceWidth: CGFloat = 640

    static func maximumWidth(in availableWidth: CGFloat) -> CGFloat {
        max(0, min(
            CGFloat(WorkbenchLayout.maximumMavenPaneWidth),
            availableWidth - minimumWorkspaceWidth - SplitHandleView.thickness
        ))
    }

    static func minimumWidth(in availableWidth: CGFloat) -> CGFloat {
        min(CGFloat(WorkbenchLayout.minimumMavenPaneWidth), maximumWidth(in: availableWidth))
    }

    static func resolvedWidth(_ width: CGFloat, in availableWidth: CGFloat) -> CGFloat {
        LitheSplitPaneGeometry.clamp(
            width,
            minimum: minimumWidth(in: availableWidth),
            maximum: maximumWidth(in: availableWidth)
        )
    }
}

/// The shared split container owns live drag state; the workbench receives only
/// the committed width, keeping persistence and full-page redraws off the hot path.
struct WorkbenchRightToolSplitView<Workspace: View, Tool: View>: View {
    let width: CGFloat
    let hasWorkbenchBackground: Bool
    let onCommit: (CGFloat) -> Void
    private let workspace: Workspace
    private let tool: Tool

    init(
        width: CGFloat,
        hasWorkbenchBackground: Bool,
        onCommit: @escaping (CGFloat) -> Void,
        @ViewBuilder workspace: () -> Workspace,
        @ViewBuilder tool: () -> Tool
    ) {
        self.width = width
        self.hasWorkbenchBackground = hasWorkbenchBackground
        self.onCommit = onCommit
        self.workspace = workspace()
        self.tool = tool()
    }

    var body: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .trailing,
                defaultSize: WorkbenchRightToolGeometry.resolvedWidth(width, in: geometry.size.width),
                minimum: WorkbenchRightToolGeometry.minimumWidth(in: geometry.size.width),
                maximum: WorkbenchRightToolGeometry.maximumWidth(in: geometry.size.width),
                showsIdleDivider: false,
                onCommit: onCommit,
                sized: {
                    tool
                        .frame(maxHeight: .infinity)
                        .workbenchPaneChrome(
                            background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                            surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                            roundsCorners: !hasWorkbenchBackground
                        )
                        .clipped()
                },
                flexible: { workspace }
            )
        }
    }
}
