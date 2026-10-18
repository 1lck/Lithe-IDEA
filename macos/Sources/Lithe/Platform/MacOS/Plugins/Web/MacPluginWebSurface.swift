import AppKit
import SwiftUI

/// The body of a plugin web tool window. The page is created the first time
/// the window shows and stays loaded, detached, while the window is hidden.
struct MacPluginWebToolWindowContent: View {
    let windowID: String
    @ObservedObject var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if model.pluginWebPageAwaitsRestart(windowID) {
            Text("Restart Lithe to load the updated page.")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .onAppear { model.closeStalePluginWebPages() }
        } else {
            MacPluginWebSurface(windowID: windowID, model: model, theme: MacPluginWebTheme(
                colorTheme: settings.colorTheme,
                isDark: colorScheme == .dark,
                codeFontFamily: settings.editorFontFamily,
                codeFontSize: settings.editorFontSize
            ))
        }
    }
}

private struct MacPluginWebSurface: NSViewRepresentable {
    let windowID: String
    let model: AppModel
    let theme: MacPluginWebTheme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Hiding the window keeps the page; only its view leaves the hierarchy.
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let pages = model.services.pluginWebPages
        guard let page = pages.page(for: windowID, make: { window in
            MacPluginWebPage(window: window, host: model, stateStore: pages.stateStore, theme: theme)
        }) else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        page.update(theme: theme)
        guard let view = page.webView, view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
