import SwiftUI
import AppKit

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
        .background(EditorCursorShieldView(cursor: .arrow))
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

/// A native AppKit view placed behind the button to establish a cursor rect and tracking area,
/// preventing the underlying WebKit text cursor (I-beam) from claiming the pointer.
private struct EditorCursorShieldView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorShieldNSView {
        let view = CursorShieldNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorShieldNSView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CursorShieldNSView: NSView {
    var cursor: NSCursor = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        cursor.set()
    }
}
