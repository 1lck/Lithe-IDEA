import AppKit
import Testing
@testable import Lithe

/// Sequence emitted when the background changes: SwiftTerm's OSC 11 answer plus the kitty DSR 997 notification.
@Suite("Terminal background change reporting")
struct MacTerminalBackgroundReportingTests {
    @Test
    func payloadMatchesSwiftTermOsc11AnswerFormat() {
        #expect(MacTerminalBackgroundReporting.osc11Payload(for: .white) == "rgb:ffff/ffff/ffff")
        #expect(MacTerminalBackgroundReporting.osc11Payload(for: .black) == "rgb:0000/0000/0000")
        // SwiftTerm converts via UInt16(component * 65535), so Lithe's dark editor #191A1C reports 1919/1a1a/1c1c.
        let editorDark = NSColor(srgbRed: 25 / 255, green: 26 / 255, blue: 28 / 255, alpha: 1)
        #expect(MacTerminalBackgroundReporting.osc11Payload(for: editorDark) == "rgb:1919/1a1a/1c1c")
    }

    @Test
    func wallpaperTransparencyIsReportedAsBlack() {
        let transparentBlack = NSColor.black.withAlphaComponent(0)
        #expect(MacTerminalBackgroundReporting.osc11Payload(for: transparentBlack) == "rgb:0000/0000/0000")
    }

    @Test
    func changeNotificationAppendsKittyRequeryRequest() {
        let notification = MacTerminalBackgroundReporting.changeNotification(for: .white)
        #expect(notification == "\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\\u{1b}[?997;2n")
    }
}
