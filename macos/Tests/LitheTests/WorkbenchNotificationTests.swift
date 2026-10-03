import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Lithe

@Suite("Workbench notifications", .serialized)
@MainActor
struct WorkbenchNotificationTests {
    @Test
    func notificationTimersPauseIndividuallyAndWhileTheApplicationIsInactive() async {
        let clock = NotificationTestClock()
        let feature = WorkbenchNotificationFeatureModel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        defer { feature.clear(); clock.releaseAll() }
        feature.setApplicationActive(false)
        feature.show("First")
        feature.show("Second")
        let firstID = feature.activeNotifications[0].id
        clock.advance(.seconds(100))
        #expect(clock.pending.isEmpty)
        #expect(feature.activeNotifications.count == 2)

        feature.setApplicationActive(true)
        await clock.settle { clock.pending.count == 2 }
        #expect(clock.pending.values.allSatisfy { clock.now.duration(to: $0.deadline) == .seconds(10) })
        clock.advance(.seconds(4))
        feature.setHovered(firstID, isHovered: true)
        await clock.settle { clock.pending.count == 1 }
        clock.advance(.seconds(6))
        await clock.settle { feature.activeNotifications.map(\.message) == ["First"] }

        feature.setApplicationActive(false)
        feature.setHovered(firstID, isHovered: false)
        clock.advance(.seconds(100))
        #expect(feature.activeNotifications.count == 1)
        feature.setApplicationActive(true)
        await clock.settle { clock.pending.count == 1 }
        #expect(clock.pending.values.first.map { clock.now.duration(to: $0.deadline) } == .seconds(6))
        clock.advance(.seconds(5))
        #expect(feature.activeNotifications.count == 1)
        clock.advance(.seconds(1))
        await clock.settle { feature.activeNotifications.isEmpty && clock.pending.isEmpty }
        #expect(feature.notifications.count == 2)
    }

    @Test
    func overflowCollapsesIntoHistoryAndClosingBalloonsPreservesMessages() {
        let feature = WorkbenchNotificationFeatureModel()
        feature.setApplicationActive(false)
        for index in 1...5 { feature.show("Message \(index)") }
        #expect(feature.activeNotifications.map(\.message) == ["Message 3", "Message 4", "Message 5"])
        #expect(feature.activeNotifications.map(\.collapsedCount) == [2, 0, 0])
        feature.dismissAll()
        #expect(feature.activeNotifications.isEmpty)
        #expect(feature.notifications.count == 5)
        feature.markAllRead()
        #expect(feature.notifications.allSatisfy { $0.isRead })
        feature.clear()
        #expect(feature.notifications.isEmpty)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func balloonUsesSourceColorsAndWrapsLongMessages(scheme: ColorScheme) throws {
        MacBundledFontRegistry.registerFonts()
        let iconRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for path in ["expui/status/info.svg", "expui/general/close.svg", "expui/general/chevronUp.svg"] {
            for asset in [path, LitheIcons.darkIdeaAssetPath(for: path)] {
                #expect(try #require(NSImage(contentsOf: iconRoot.appendingPathComponent(asset))).size == NSSize(width: 16, height: 16))
            }
        }
        var shortHeight: CGFloat = 0
        for message in ["Java 服务正在准备", String(repeating: "A long notification must stay readable. ", count: 6)] {
            let host = NSHostingView(rootView: WorkbenchNotificationBanner(message: message, dismiss: {})
                .environment(\.colorScheme, scheme))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == 360)
            if shortHeight == 0 {
                shortHeight = host.bounds.height
                #expect(shortHeight >= 48 && shortHeight < 65)
            } else {
                #expect(host.bounds.height > shortHeight && host.bounds.height < shortHeight * 2,
                        "Long notifications initially show two lines instead of covering the workbench")
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            func expectColor(_ hex: UInt32, y: CGFloat) throws {
                let color = try #require(bitmap.colorAt(x: Int(180 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
                #expect(abs(color.redComponent - CGFloat((hex >> 16) & 255) / 255) < 0.01)
                #expect(abs(color.greenComponent - CGFloat((hex >> 8) & 255) / 255) < 0.01)
                #expect(abs(color.blueComponent - CGFloat(hex & 255) / 255) < 0.01)
            }
            try expectColor(scheme == .dark ? 0x33353B : 0xFFFFFF, y: host.bounds.height - 10)
            try expectColor(scheme == .dark ? 0x33353B : 0xD1D3D9, y: 0)
            if let directory = ProcessInfo.processInfo.environment["LITHE_NOTIFICATION_CAPTURE_DIR"] {
                let name = "notification-\(scheme == .dark ? "dark" : "light")-\(message.count < 20 ? "short" : "long").png"
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    @Test
    func notificationsAreNewestFirstReadableBoundedAndClearable() {
        let store = WorkbenchNotificationTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)

        for index in 0..<101 {
            model.showNotification("Message \(index)")
        }

        #expect(model.notifications.count == 100)
        #expect(model.notifications.first?.message == "Message 100")
        #expect(model.notifications.last?.message == "Message 1")
        #expect(model.notifications.allSatisfy { !$0.isRead })
        #expect(model.activeNotifications.map(\.message) == ["Message 98", "Message 99", "Message 100"])

        model.setNotificationHovered(model.activeNotifications[0].id, isHovered: true)
        model.showNotification("Message 101")
        #expect(model.activeNotifications.map(\.message) == ["Message 99", "Message 100", "Message 101"])

        let dismissedID = model.activeNotifications[1].id
        model.dismissNotification(dismissedID)
        #expect(model.activeNotifications.map(\.message) == ["Message 99", "Message 101"])

        model.markAllNotificationsRead()
        #expect(model.notifications.allSatisfy { $0.isRead })

        model.clearNotifications()
        #expect(model.notifications.isEmpty)
        #expect(model.activeNotifications.isEmpty)
    }

    @Test
    func disabledYAMLLanguageServerDoesNotShowAStartupError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-disabled-yaml-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkbenchNotificationTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        model.openProjectDirectly(root)
        model.clearNotifications()

        let document = EditorDocument(
            url: root.appendingPathComponent("config.yaml"),
            text: "enabled: true\n",
            modificationDate: nil
        )

        #expect(!model.activateLanguageServerIfAvailable(for: document))

        // A regression used to enqueue activation and report moduleDisabled on
        // the next task turn, so yield before checking the notification queue.
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(!model.notifications.contains {
            $0.message.contains("Could not start YAML language server")
        })
    }

}

@MainActor
private final class NotificationTestClock {
    var now = ContinuousClock().now
    var pending: [UUID: (deadline: ContinuousClock.Instant, gate: TestGate)] = [:]

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let gate = TestGate()
        pending[id] = (now.advanced(by: duration), gate)
        defer { pending.removeValue(forKey: id) }
        guard await gate.waitUntilOpen() else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func advance(_ duration: Duration) {
        now = now.advanced(by: duration)
        for wait in pending.values where wait.deadline <= now { wait.gate.open() }
    }

    func releaseAll() { pending.values.forEach { $0.gate.open() } }

    func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock().now < deadline { await Task.yield() }
        #expect(condition(), "Notification task did not reach the expected clock boundary")
    }
}

private final class WorkbenchNotificationTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
