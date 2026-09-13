import SwiftUI

/// 主编辑器右上角的软换行开关：样式对齐 Git Console 的换行切换，
/// 状态经 AppSettings 持久化；超大文件（行数阈值见 `LitheTextViewportLayout`）
/// 时按钮禁用，布局层兜底保持不换行。
struct EditorSoftWrapToggle: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chrome: EditorChromeModel

    var body: some View {
        Button {
            settings.editorSoftWrapEnabled.toggle()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "text.justify.leading")
                    .font(.system(size: 12, weight: .regular))
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 6.5, weight: .semibold))
                    .offset(x: 2, y: 1)
            }
        }
        .litheIconButton()
        .foregroundStyle(settings.editorSoftWrapEnabled ? LitheTheme.accent : LitheTheme.secondaryText)
        .disabled(!chrome.isSoftWrapAvailable)
        .help(helpText)
        .accessibilityLabel(Text("Soft Wraps"))
        .accessibilityValue(Text(settings.editorSoftWrapEnabled ? "On" : "Off"))
    }

    private var helpText: LocalizedStringKey {
        if !chrome.isSoftWrapAvailable {
            return "Soft wrap is unavailable for very large files"
        }
        return settings.editorSoftWrapEnabled ? "Disable soft wraps" : "Use soft wraps"
    }
}
