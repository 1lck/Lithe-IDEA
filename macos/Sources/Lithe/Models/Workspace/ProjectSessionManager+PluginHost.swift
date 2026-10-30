import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// Finds the project window a plugin was given the ID of. A closed window is
/// no longer a session, so its ID finds nothing.
@MainActor
extension ProjectSessionManager: PluginHostWindowDirectory {
    func hostWindow(id: UUID) -> (any PluginHostWindowPort)? {
        session(for: id)
    }
}
