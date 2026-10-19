import AppKit
import SwiftUI

/// Native settings and shared toolbar metrics for the WebKit-owned soft-wrap button.
/// Keeping the hit target inside WebKit prevents competing native/text cursor owners.
struct EditorSoftWrapToggleConfiguration: Equatable {
    let visible: Bool
    let enabled: Bool
    let selected: Bool
    let hover: String
    let pressed: String

    init(visible: Bool, enabled: Bool, selected: Bool) {
        self.visible = visible
        self.enabled = enabled
        self.selected = selected
        let style = LitheIconButtonStyle()
        hover = MonacoWorkbenchThemeConfiguration.cssColor(NSColor(style.hoverBackground))
        pressed = MonacoWorkbenchThemeConfiguration.cssColor(NSColor(style.pressedBackground))
    }

    var bridgePayload: [String: Any] {
        let style = LitheIconButtonStyle()
        let title = !enabled ? String(localized: "Soft wrap is unavailable for very large files")
            : selected ? String(localized: "Disable soft wraps") : String(localized: "Use soft wraps")
        return ["visible": visible, "enabled": enabled, "selected": selected,
                "label": String(localized: "Soft Wraps"), "title": title,
                "size": LitheTheme.Metrics.toolbarIconButtonSize, "radius": style.cornerRadius,
                "disabledOpacity": style.disabledOpacity, "hover": hover, "pressed": pressed]
    }
}
