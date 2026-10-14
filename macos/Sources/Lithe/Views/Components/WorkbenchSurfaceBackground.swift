import SwiftUI

private struct WorkbenchBackgroundImageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Native child views need the same wallpaper state as structural SwiftUI surfaces.
    var hasWorkbenchBackgroundImage: Bool {
        get { self[WorkbenchBackgroundImageKey.self] }
        set { self[WorkbenchBackgroundImageKey.self] = newValue }
    }
}

/// Applies the workbench wallpaper treatment to structural page surfaces while
/// preserving the normal theme color when no wallpaper is configured.
private struct WorkbenchSurfaceBackground: ViewModifier {
    @EnvironmentObject private var model: AppModel

    let fallback: Color

    func body(content: Content) -> some View {
        content.litheWorkbenchSurface(fallback, hasBackgroundImage: model.workbenchBackgroundFeature.hasImage)
            .environment(\.hasWorkbenchBackgroundImage, model.workbenchBackgroundFeature.hasImage)
    }
}

extension View {
    /// Explicit state for leaf/native controls that do not own an AppModel.
    func litheWorkbenchSurface(_ fallback: Color, hasBackgroundImage: Bool) -> some View {
        background(hasBackgroundImage ? Color.clear : fallback)
    }

    /// Use for the background of a workbench page, pane, or title bar.
    /// Inputs, selections, menus, and modal controls deliberately retain their
    /// own backgrounds so that the wallpaper never reduces their readability.
    func litheWorkbenchSurface(_ fallback: Color) -> some View {
        modifier(WorkbenchSurfaceBackground(fallback: fallback))
    }
}
