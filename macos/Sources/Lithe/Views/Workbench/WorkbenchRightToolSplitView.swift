import SwiftUI

enum WorkbenchRightToolGeometry {
    // IDEA's trailing splitter keeps the first pane at its current width,
    // then lets the editor shrink to the shared minimum.
    static func minimumWorkspaceWidth(sidebarWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        CGFloat(WorkbenchLayout.minimumPaneSize)
            + (isSidebarVisible ? max(sidebarWidth, CGFloat(WorkbenchLayout.minimumPaneSize))
                + SplitHandleView.thickness : 0)
    }

    static func maximumWidth(in availableWidth: CGFloat, sidebarWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        max(0, availableWidth - minimumWorkspaceWidth(sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible)
            - SplitHandleView.thickness)
    }

    static func minimumWidth(in availableWidth: CGFloat, sidebarWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        min(CGFloat(WorkbenchLayout.minimumPaneSize),
            maximumWidth(in: availableWidth, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible))
    }

    static func resolvedWidth(_ width: CGFloat, in availableWidth: CGFloat, sidebarWidth: CGFloat, isSidebarVisible: Bool) -> CGFloat {
        LitheSplitPaneGeometry.clamp(
            width,
            minimum: minimumWidth(in: availableWidth, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible),
            maximum: maximumWidth(in: availableWidth, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible)
        )
    }

    /// A window with no usable resize range is showing a temporary fit value.
    /// It must not replace the user's preferred width when a drag ends.
    static func committedWidth(
        _ width: CGFloat,
        preferredWidth: CGFloat,
        in availableWidth: CGFloat,
        sidebarWidth: CGFloat,
        isSidebarVisible: Bool
    ) -> CGFloat? {
        let maximum = maximumWidth(in: availableWidth, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible)
        guard maximum > CGFloat(WorkbenchLayout.minimumPaneSize) else {
            return nil
        }
        // A window resize can clamp the displayed width without a user drag.
        if preferredWidth > maximum, width >= maximum { return nil }
        return resolvedWidth(width, in: availableWidth, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible)
    }
}

/// The shared split container owns live drag state; the workbench receives only
/// the committed width, keeping persistence and full-page redraws off the hot path.
struct WorkbenchRightToolSplitView<Workspace: View, Tool: View>: View {
    let width: CGFloat
    let sidebarWidth: CGFloat
    let isSidebarVisible: Bool
    let hasWorkbenchBackground: Bool
    let showsFrameGradient: Bool
    let onCommit: (CGFloat) -> Void
    private let workspace: Workspace
    private let tool: Tool

    init(
        width: CGFloat,
        sidebarWidth: CGFloat,
        isSidebarVisible: Bool,
        hasWorkbenchBackground: Bool,
        showsFrameGradient: Bool = false,
        onCommit: @escaping (CGFloat) -> Void,
        @ViewBuilder workspace: () -> Workspace,
        @ViewBuilder tool: () -> Tool
    ) {
        self.width = width
        self.sidebarWidth = sidebarWidth
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
                defaultSize: WorkbenchRightToolGeometry.resolvedWidth(width, in: geometry.size.width, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible),
                minimum: WorkbenchRightToolGeometry.minimumWidth(in: geometry.size.width, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible),
                maximum: WorkbenchRightToolGeometry.maximumWidth(in: geometry.size.width, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible),
                clipsSizedPane: true,
                trackBackground: hasWorkbenchBackground ? LitheTheme.titlebar.opacity(0.7) : .clear,
                showsIdleDivider: false,
                onCommit: { width in
                    guard let committedWidth = WorkbenchRightToolGeometry.committedWidth(
                        width,
                        preferredWidth: self.width,
                        in: geometry.size.width,
                        sidebarWidth: sidebarWidth,
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
