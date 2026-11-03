import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// Opens web addresses and saved HTML files through the platform's browser
/// handling. The browser service has already decided what may be opened.
@MainActor
final class PluginHostPlatformBrowser: PluginHostExternalOpening {
    private let platformUI: any PlatformUI

    init(platformUI: any PlatformUI) {
        self.platformUI = platformUI
    }

    func openWebURL(_ url: URL) async throws {
        try await platformUI.openWebURLInBrowser(url)
    }

    func openLocalHTMLFile(_ url: URL) async throws {
        try await platformUI.openHTMLInBrowser(url)
    }
}

/// The host-internal services behind `editor.open`, `editor.reveal`,
/// `preview.openHTML`, `browser.openExternal` and `window.show*`.
///
/// They are not a plugin API. The function bridge that routes plugin calls
/// builds a `PluginHostCallContext` from the plugin's activation and calls
/// these, after it has checked the plugin's grants.
@MainActor
struct PluginHostWindowServices {
    let editor: PluginHostEditorService
    let preview: PluginHostPreviewService
    let browser: PluginHostBrowserService
    let messages: PluginHostMessageService

    init(
        directory: any PluginHostWindowDirectory,
        fileStorage: any FileStorage,
        platformUI: any PlatformUI
    ) {
        let resolver = PluginHostResourceResolver(fileStorage: fileStorage)
        let editor = PluginHostEditorService(directory: directory, resolver: resolver)
        self.editor = editor
        preview = PluginHostPreviewService(editor: editor, directory: directory)
        browser = PluginHostBrowserService(
            directory: directory, resolver: resolver, opener: PluginHostPlatformBrowser(platformUI: platformUI)
        )
        messages = PluginHostMessageService(directory: directory)
    }
}
