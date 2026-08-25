/// Native surfaces that can reveal the workbench wallpaper behind their content.
/// Platform-native views own the concrete rendering and restoration behavior.
@MainActor
protocol WorkbenchBackgroundRendering: AnyObject {
    func setWorkbenchBackgroundVisible(_ isVisible: Bool)
}
