import Foundation
import Testing
@testable import Lithe

@Suite("Soft wrap control configuration")
@MainActor
struct EditorSoftWrapCursorTests {
    @Test func webButtonKeepsSharedMetricsAndNativeSettingState() {
        let enabled = EditorSoftWrapToggleConfiguration(visible: true, enabled: true, selected: false)
        let disabled = EditorSoftWrapToggleConfiguration(visible: false, enabled: false, selected: true)
        #expect(enabled.bridgePayload["visible"] as? Bool == true)
        #expect(enabled.bridgePayload["enabled"] as? Bool == true)
        #expect(enabled.bridgePayload["selected"] as? Bool == false)
        #expect(enabled.bridgePayload["size"] as? CGFloat == LitheTheme.Metrics.toolbarIconButtonSize)
        #expect(disabled.bridgePayload["visible"] as? Bool == false)
        #expect(disabled.bridgePayload["enabled"] as? Bool == false)
        #expect(disabled.bridgePayload["selected"] as? Bool == true)
        #expect(enabled != disabled)
    }
}
