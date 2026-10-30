import SwiftUI

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// The plugin messages of one window, stacked at the window's lower left.
///
/// Plugin text, plugin names and button titles are the plugin's own words:
/// they are drawn with `verbatim:`, so the host never looks them up in a
/// translation table or reads them as markup. Only the host's own control
/// (the close button's label) is translated.
struct PluginHostMessageStack: View {
    @ObservedObject var messages: PluginHostMessageFeatureModel

    var body: some View {
        if !messages.visible.isEmpty {
            VStack(alignment: .leading, spacing: 2 * LitheTheme.Notification.shadowInset) {
                ForEach(messages.visible) { entry in
                    PluginHostMessageBanner(
                        entry: entry,
                        choose: { messages.choose(entry.id, index: $0) },
                        dismiss: { messages.dismiss(entry.id) }
                    )
                }
            }
            .padding(.leading, LitheTheme.Notification.edgeInset)
            .padding(.bottom, LitheTheme.Metrics.statusBarHeight + LitheTheme.Notification.edgeInset)
        }
    }
}

/// One plugin message: severity icon, plugin name, text and its buttons.
struct PluginHostMessageBanner: View {
    let entry: PluginHostMessageEntry
    let choose: (Int) -> Void
    let dismiss: () -> Void

    private var iconPath: String {
        switch entry.severity {
        case .information: "expui/status/info.svg"
        case .warning: "expui/status/warning.svg"
        case .error: "expui/status/error.svg"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LitheIDEAIcon(resourcePath: iconPath, size: 16, preservesOriginalColors: true)
                .padding(.top, 15)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.pluginName)
                    .font(LitheTheme.uiFont(size: 11, weight: .regular))
                    .foregroundStyle(LitheTheme.Notification.moreForeground)
                    .lineLimit(1)
                Text(verbatim: entry.text)
                    .font(LitheTheme.uiFont(size: 13, weight: .regular))
                    .foregroundStyle(LitheTheme.Notification.foreground)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.actions.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(Array(entry.actions.enumerated()), id: \.offset) { index, title in
                            Button(action: { choose(index) }) {
                                Text(verbatim: title)
                            }
                            .buttonStyle(.litheNoPress)
                            .font(LitheTheme.uiFont(size: 13))
                            .foregroundStyle(LitheTheme.accent)
                            .accessibilityIdentifier("plugin-host-message-action-\(index)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .padding(.leading, 14)
        .padding(.trailing, 32)
        .frame(width: LitheTheme.Notification.width, alignment: .topLeading)
        .litheNotificationSurface()
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: 16, preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: 20, cornerRadius: 4,
                                              hoverBackground: LitheTheme.Notification.iconHover))
            .padding(.top, 7)
            .padding(.trailing, 7)
            .accessibilityLabel("Dismiss notification")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-host-message")
    }
}
