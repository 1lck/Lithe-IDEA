import AppKit
import Testing
@testable import Lithe

@Suite("Window fullscreen capability guard")
@MainActor
struct WindowFullScreenCapabilityGuardTests {
    @Test
    func guardStripsSwiftUIFullScreenRefusalWhenInstalled() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        window.collectionBehavior.insert(.fullScreenNone)

        window.contentView?.addSubview(WindowFullScreenCapabilityView())

        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test
    func guardRewiresZoomButtonToTheGuardedFullscreenToggle() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        window.collectionBehavior.insert(.fullScreenNone)

        let guardView = WindowFullScreenCapabilityView()
        window.contentView?.addSubview(guardView)

        // AppKit configures the zoom button while the window is created, so a
        // button configured under the refusal would keep maximizing until the
        // guard rewires it.
        let zoomButton = try #require(window.standardWindowButton(.zoomButton))
        #expect(zoomButton.target as? WindowFullScreenCapabilityView === guardView)
        #expect(zoomButton.action == #selector(WindowFullScreenCapabilityView.zoomButtonClicked(_:)))
    }

    @Test
    func guardRestripsTheRefusalWhenSwiftUIReappliesIt() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        window.collectionBehavior.insert(.fullScreenNone)

        window.contentView?.addSubview(WindowFullScreenCapabilityView())
        #expect(!window.collectionBehavior.contains(.fullScreenNone))

        // SwiftUI reapplies the flag during scene updates; the next window
        // update pass must strip it again so the zoom button stays usable.
        window.collectionBehavior.insert(.fullScreenNone)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}

@Suite("Window fullscreen state reader")
@MainActor
struct WindowFullScreenStateReaderTests {
    @Test
    func readerTracksFullScreenTransitionsThroughWindowUpdates() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var reported: [Bool] = []
        let reader = WindowFullScreenStateReader.ReaderView()
        reader.onRefresh = { value in reported.append(value) }
        window.contentView?.addSubview(reader)
        #expect(reported == [false])

        // AppKit throws when tests write the style mask outside a real
        // fullscreen transition, so the state is driven through the
        // injectable predicate instead.
        reader.isFullScreen = { _ in true }
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(reported == [false, true])

        reader.isFullScreen = { _ in false }
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(reported == [false, true, false])
    }
}

@Suite("Window layout transition while fullscreen")
@MainActor
struct WindowLayoutFullScreenTransitionTests {
    private final class Sessions: ProjectWindowSessionHandling {
        var hasUnsavedDocuments = false
        var closingDocuments: [EditorDocument] = []
        var unsavedDocumentNames: [String] = []
        var hasActiveProject = false
        var hasActiveStandaloneFile = false
        var shouldDismissWindowWhenClosingActiveSession = false
        var windowScope: ProjectWindowScope = .primary

        @discardableResult
        func saveAllDocuments() async -> Bool { true }
        func closeActiveProject() {}
        func requestCloseActiveWorkbenchItem() -> Bool { false }
        func requestCloseActiveSession() -> Bool { true }
        func resetForProjectWindowClose() async {}
        func confirmRunServicesBeforeClose() async -> Bool { true }
        func noteWindowBecameKey() {}
    }

    @Test
    func layoutTransitionWhileFullScreenDefersFrameSwapUntilExit() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let coordinator = LitheWindowCoordinator(projectSessions: Sessions())
        coordinator.attach(to: window, layout: .welcome, title: "Welcome")
        let welcomeWidth = window.frame.width
        #expect(abs(welcomeWidth - LitheWindowLayout.welcomeContentSize.width) < 1)

        // 欢迎页全屏后打开项目：全屏期间不得把窗口缩成居中的工作台默认尺寸
        coordinator.isInFullScreen = { _ in true }
        coordinator.attach(to: window, layout: .workspace, title: "Project")
        #expect(abs(window.frame.width - welcomeWidth) < 1)

        // 退出全屏后补一次换框，落回工作台默认尺寸。期望值必须经过与
        // applyFrame 相同的屏幕钳制：CI 的虚拟显示器只有 1024pt 宽，
        // 不能直接断言 1440。
        coordinator.isInFullScreen = { _ in false }
        coordinator.windowDidExitFullScreen(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )
        let expectedWorkspaceWidth: CGFloat
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            expectedWorkspaceWidth = LitheWindowLayout.frame(
                NSRect(origin: .zero, size: LitheWindowLayout.workspaceContentSize),
                fitting: visibleFrame
            ).width
        } else {
            // applyFrame 只在有可见屏幕时钳制；无屏幕环境不缩放。
            expectedWorkspaceWidth = LitheWindowLayout.workspaceContentSize.width
        }
        #expect(abs(window.frame.width - expectedWorkspaceWidth) < 1)
    }

    @Test
    func directFullScreenExitWithoutLayoutChangeKeepsRestoredFrame() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let coordinator = LitheWindowCoordinator(projectSessions: Sessions())
        coordinator.attach(to: window, layout: .welcome, title: "Welcome")
        let welcomeWidth = window.frame.width

        // 全屏前全屏后布局未变：退出时不做换框，保留退出前的窗口尺寸
        coordinator.isInFullScreen = { _ in true }
        coordinator.windowDidExitFullScreen(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )
        #expect(abs(window.frame.width - welcomeWidth) < 1)
    }
}
