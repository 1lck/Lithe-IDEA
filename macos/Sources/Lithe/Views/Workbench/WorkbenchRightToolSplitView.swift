import SwiftUI

enum WorkbenchRightToolGeometry {
    static func minimumWorkspaceWidth(isSidebarVisible: Bool) -> CGFloat {
        CGFloat(WorkbenchLayout.minimumPaneSize) * (isSidebarVisible ? 2 : 1)
            + (isSidebarVisible ? SplitHandleView.thickness : 0)
    }

    static func maximumWidth(in availableWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        max(0, availableWidth - minimumWorkspaceWidth(isSidebarVisible: isSidebarVisible)
            - SplitHandleView.thickness)
    }

    static func minimumWidth(in availableWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        min(CGFloat(WorkbenchLayout.minimumPaneSize),
            maximumWidth(in: availableWidth, isSidebarVisible: isSidebarVisible))
    }

    static func resolvedWidth(_ width: CGFloat, in availableWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        LitheSplitPaneGeometry.clamp(
            width,
            minimum: minimumWidth(in: availableWidth, isSidebarVisible: isSidebarVisible),
            maximum: maximumWidth(in: availableWidth, isSidebarVisible: isSidebarVisible)
        )
    }

    /// A window with no usable resize range is showing a temporary fit value.
    /// It must not replace the user's preferred width when a drag ends.
    static func committedWidth(
        _ width: CGFloat,
        preferredWidth: CGFloat,
        in availableWidth: CGFloat,
        isSidebarVisible: Bool
    ) -> CGFloat? {
        let maximum = maximumWidth(in: availableWidth, isSidebarVisible: isSidebarVisible)
        guard maximum > CGFloat(WorkbenchLayout.minimumPaneSize) else {
            return nil
        }
        // A window resize can clamp the displayed width without a user drag.
        if preferredWidth > maximum, width >= maximum { return nil }
        return resolvedWidth(width, in: availableWidth, isSidebarVisible: isSidebarVisible)
    }
}

/// The shared split container owns live drag state; the workbench receives only
/// the committed width, keeping persistence and full-page redraws off the hot path.
struct WorkbenchRightToolSplitView<Workspace: View, Tool: View>: View {
    let width: CGFloat
    let isSidebarVisible: Bool
    let hasWorkbenchBackground: Bool
    let showsFrameGradient: Bool
    let onCommit: (CGFloat) -> Void
    private let workspace: Workspace
    private let tool: Tool

    init(
        width: CGFloat,
        isSidebarVisible: Bool,
        hasWorkbenchBackground: Bool,
        showsFrameGradient: Bool = false,
        onCommit: @escaping (CGFloat) -> Void,
        @ViewBuilder workspace: () -> Workspace,
        @ViewBuilder tool: () -> Tool
    ) {
        self.width = width
        self.isSidebarVisible = isSidebarVisible
        self.hasWorkbenchBackground = hasWorkbenchBackground
        self.showsFrameGradient = showsFrameGradient
        self.onCommit = onCommit
        self.workspace = workspace()
        self.tool = tool()
    }

    var body: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .trailing,
                defaultSize: WorkbenchRightToolGeometry.resolvedWidth(width, in: geometry.size.width, isSidebarVisible: isSidebarVisible),
                minimum: WorkbenchRightToolGeometry.minimumWidth(in: geometry.size.width, isSidebarVisible: isSidebarVisible),
                maximum: WorkbenchRightToolGeometry.maximumWidth(in: geometry.size.width, isSidebarVisible: isSidebarVisible),
                clipsSizedPane: true,
                trackBackground: hasWorkbenchBackground ? LitheTheme.titlebar.opacity(0.7) : .clear,
                showsIdleDivider: false,
                onCommit: { width in
                    guard let committedWidth = WorkbenchRightToolGeometry.committedWidth(
                        width,
                        preferredWidth: self.width,
                        in: geometry.size.width,
                        isSidebarVisible: isSidebarVisible
                    ) else { return }
                    onCommit(committedWidth)
                },
                sized: {
                    tool
                        .workbenchResizablePaneChrome(
                            background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                            surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                            alignment: .topTrailing,
                            roundsCorners: !hasWorkbenchBackground,
                            showsFrameGradient: showsFrameGradient
                        )
                },
                flexible: { workspace }
            )
            .background(hasWorkbenchBackground || showsFrameGradient ? Color.clear : LitheTheme.titlebar)
        }
    }
}
