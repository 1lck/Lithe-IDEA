import AppKit
import Testing
@testable import Lithe

/// Notifications emitted on background changes for programs subscribed to kitty DEC mode 2031.
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
    func doesNotNotifyWhenUnsubscribed() {
        #expect(MacTerminalBackgroundReporting.changeNotification(for: .white, isSubscribed: false) == nil)
    }

    @Test
    func changeNotificationReportsLightStateForLightBackground() {
        let notification = MacTerminalBackgroundReporting.changeNotification(for: .white, isSubscribed: true)
        #expect(notification == "\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\\u{1b}[?997;2n")
    }

    @Test
    func changeNotificationReportsDarkStateForDarkBackground() {
        let notification = MacTerminalBackgroundReporting.changeNotification(for: .black, isSubscribed: true)
        #expect(notification == "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\\u{1b}[?997;1n")
    }

    @Test
    func changeNotificationReportsDarkStateForWallpaperTransparency() {
        let transparentBlack = NSColor.black.withAlphaComponent(0)
        let notification = MacTerminalBackgroundReporting.changeNotification(for: transparentBlack, isSubscribed: true)
        #expect(notification == "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\\u{1b}[?997;1n")
    }
}

@Suite("Kitty background-change subscription")
struct MacTerminalBackgroundSubscriptionTests {
    @Test
    func startsUnsubscribed() {
        #expect(!MacTerminalBackgroundSubscription().isSubscribed)
    }

    @Test
    func subscribesOnDecMode2031Set() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        #expect(subscription.isSubscribed)
    }

    @Test
    func subscribesWhenMode2031IsCombinedWithOtherDecModes() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?1;2031h".utf8)
        #expect(subscription.isSubscribed)
    }

    @Test
    func doesNotSubscribeToModeWithSimilarNumber() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?20310h".utf8)
        #expect(!subscription.isSubscribed)
    }

    @Test
    func unsubscribesOnDecMode2031Reset() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.feed("\u{1b}[?2031l".utf8)
        #expect(!subscription.isSubscribed)
    }

    @Test
    func detectsMarkerSplitAcrossChunks() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?20".utf8)
        #expect(!subscription.isSubscribed)
        subscription.feed("31h".utf8)
        #expect(subscription.isSubscribed)
    }

    @Test
    func terminalResetClearsSubscription() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.feed("\u{1b}c".utf8)
        #expect(!subscription.isSubscribed)
    }

    @Test
    func processRestartClearsSubscription() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.reset()
        #expect(!subscription.isSubscribed)
    }

    @Test
    func altScreen1049ExitClearsSubscription() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.feed("\u{1b}[?1049l".utf8)
        #expect(!subscription.isSubscribed)
    }

    @Test
    func altScreen47ExitClearsSubscription() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.feed("\u{1b}[?47l".utf8)
        #expect(!subscription.isSubscribed)
    }

    @Test
    func altScreen1047ExitClearsSubscription() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.feed("\u{1b}[?1047l".utf8)
        #expect(!subscription.isSubscribed)
    }

    @Test
    func altScreenEnterKeepsSubscription() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("\u{1b}[?2031h".utf8)
        subscription.feed("\u{1b}[?1049h".utf8)
        #expect(subscription.isSubscribed)
    }

    @Test
    func plainOutputStaysUnsubscribed() {
        var subscription = MacTerminalBackgroundSubscription()
        subscription.feed("ls -la\r\nhello world".utf8)
        #expect(!subscription.isSubscribed)
    }
}
