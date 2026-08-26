import SwiftUI

/// Applies the workbench wallpaper treatment to structural page surfaces while
/// preserving the normal theme color when no wallpaper is configured.
private struct WorkbenchSurfaceBackground: ViewModifier {
    @EnvironmentObject private var model: AppModel

    let fallback: Color

    func body(content: Content) -> some View {
        content.background(model.workbenchBackgroundFeature.hasImage ? Color.clear : fallback)
    }
}

extension View {
    /// Use for the background of a workbench page, pane, or title bar.
    /// Inputs, selections, menus, and modal controls deliberately retain their
    /// own backgrounds so that the wallpaper never reduces their readability.
    func litheWorkbenchSurface(_ fallback: Color) -> some View {
        modifier(WorkbenchSurfaceBackground(fallback: fallback))
    }
}
