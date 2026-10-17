import SwiftUI

/// 缩略图左侧的软换行开关：复用统一工具栏按钮样式，
/// 状态经 AppSettings 持久化；超大文件（行数阈值见 `LitheTextViewportLayout`）
/// 时按钮禁用，布局层兜底保持不换行。
struct EditorSoftWrapToggle: View {
    @ObservedObject var session: MonacoWorkbenchSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chrome: EditorChromeModel

    var body: some View {
        // 查找栏是覆盖在编辑器顶部的悬浮弹层，窄面板（分屏、展开侧边
        // 工具窗口）下会占满可用宽度。此时隐藏本开关，避免盖住查找栏
        // 关闭按钮的点击区域。
        if !chrome.isFindBarVisible, let inset = session.minimapTrailingInset {
            softWrapButton
                .padding(.top, 8)
                .padding(.trailing, inset + 8)
        }
    }

    private var softWrapButton: some View {
        Button {
            settings.editorSoftWrapEnabled.toggle()
        } label: {
            LitheIDEAIcon(resourcePath: "expui/general/softWrap.svg", size: 16, preservesOriginalColors: true)
        }
        .buttonStyle(LitheIconButtonStyle(
            size: LitheTheme.Metrics.toolbarIconButtonSize,
            isSelected: settings.editorSoftWrapEnabled
        ))
        .disabled(!chrome.isSoftWrapAvailable)
        // The underlying WebKit editor otherwise retains its text cursor over this overlay.
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
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
