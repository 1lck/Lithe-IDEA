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
        await clock.settle("two dismissal tasks registered") { clock.pending.count == 2 }
        #expect(clock.pending.values.allSatisfy { clock.now.duration(to: $0.deadline) == .seconds(10) })
        clock.advance(.seconds(4))
        feature.setHovered(firstID, isHovered: true)
        await clock.settle("one dismissal task registered") { clock.pending.count == 1 }
        clock.advance(.seconds(6))
        await clock.settle("first balloon dismissed") { feature.activeNotifications.map(\.message) == ["First"] }

        feature.setApplicationActive(false)
        feature.setHovered(firstID, isHovered: false)
        clock.advance(.seconds(100))
        #expect(feature.activeNotifications.count == 1)
        feature.setApplicationActive(true)
        await clock.settle("one dismissal task registered") { clock.pending.count == 1 }
        #expect(clock.pending.values.first.map { clock.now.duration(to: $0.deadline) } == .seconds(6))
        clock.advance(.seconds(5))
        #expect(feature.activeNotifications.count == 1)
        clock.advance(.seconds(1))
        await clock.settle("all balloons dismissed") { feature.activeNotifications.isEmpty && clock.pending.isEmpty }
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
            let host = NSHostingView(rootView: WorkbenchNotificationBanner(message: message,
                occurrenceCount: 1, dismiss: {})
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
    func repeatedMessagesMergeIntoOneUnreadEntryAndCountOccurrences() throws {
        let feature = WorkbenchNotificationFeatureModel()
        feature.setApplicationActive(false)
        defer { feature.clear() }

        feature.show("Java service is ready")
        #expect(feature.notifications.map(\.occurrenceCount) == [1])
        #expect(feature.activeNotifications.map(\.occurrenceCount) == [1])

        feature.show("Java service is ready")
        feature.show("No usages found")
        feature.markAllRead()
        let repeatedEntry = try #require(feature.notifications.first { $0.message == "Java service is ready" })
        #expect(feature.notifications.map(\.message) == ["No usages found", "Java service is ready"])

        feature.show("Java service is ready")

        // The third appearance must reuse the existing row instead of appending one.
        #expect(feature.notifications.map(\.message) == ["Java service is ready", "No usages found"])
        #expect(feature.notifications.map(\.occurrenceCount) == [3, 1])
        #expect(!feature.notifications[0].isRead)
        #expect(feature.notifications[0].updatedAt >= repeatedEntry.updatedAt)
        // The balloon stack follows the merge instead of growing a second card.
        #expect(feature.activeNotifications.map(\.message) == ["No usages found", "Java service is ready"])
        #expect(feature.activeNotifications.map(\.occurrenceCount) == [1, 3])
    }

    @Test
    func repeatingACollapsedMessageKeepsTheOverflowEntry() {
        let feature = WorkbenchNotificationFeatureModel()
        feature.setApplicationActive(false)
        defer { feature.clear() }

        for message in ["A", "B", "C", "D"] { feature.show(message) }
        #expect(feature.activeNotifications.map(\.message) == ["B", "C", "D"])
        #expect(feature.activeNotifications.map(\.collapsedCount) == [1, 0, 0])

        feature.show("B")

        // The repeat takes the newest slot, and the "N more notifications" entry
        // stays on the oldest balloon instead of vanishing with the history copy
        // that replaced it.
        #expect(feature.activeNotifications.map(\.message) == ["C", "D", "B"])
        #expect(feature.activeNotifications.map(\.collapsedCount) == [1, 0, 0])
        #expect(feature.notifications.map(\.message) == ["B", "D", "C", "A"])
        #expect(feature.notifications.first?.occurrenceCount == 2)
    }

    @Test
    func repeatingAnActiveMessageRestartsItsOwnBalloonDeadline() async {
        let clock = NotificationTestClock()
        let feature = WorkbenchNotificationFeatureModel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        defer { feature.clear(); clock.releaseAll() }

        feature.show("Saved")
        feature.show("Other")
        await clock.settle("two dismissal tasks registered") { clock.pending.count == 2 }

        clock.advance(.seconds(9))
        feature.show("Saved")
        #expect(feature.activeNotifications.map(\.message) == ["Other", "Saved"])
        #expect(feature.activeNotifications.map(\.occurrenceCount) == [1, 2])
        // The repeat replaces its own dismissal task, so wait for the fresh
        // window instead of a count that also holds before the swap completes.
        await clock.settle("the repeated balloon restarted its window") {
            clock.pendingRemaining.sorted() == [.seconds(1), .seconds(10)]
        }

        // The untouched message still expires on its original deadline.
        clock.advance(.seconds(2))
        await clock.settle("other balloon dismissed") { feature.activeNotifications.map(\.message) == ["Saved"] }

        // The repeated message outlives the deadline it originally had.
        clock.advance(.seconds(6))
        #expect(feature.activeNotifications.map(\.message) == ["Saved"])
        clock.advance(.seconds(2))
        await clock.settle("all balloons dismissed") { feature.activeNotifications.isEmpty }
        #expect(feature.notifications.map(\.message) == ["Saved", "Other"])
        #expect(feature.notifications.map(\.occurrenceCount) == [2, 1])
    }

    @Test
    func repeatingAMessageWhoseBalloonExpiredPresentsItAgain() async {
        let clock = NotificationTestClock()
        let feature = WorkbenchNotificationFeatureModel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        defer { feature.clear(); clock.releaseAll() }

        feature.show("Saved")
        await clock.settle("one dismissal task registered") { clock.pending.count == 1 }
        clock.advance(.seconds(10))
        await clock.settle("all balloons dismissed") { feature.activeNotifications.isEmpty }
        #expect(feature.notifications.map(\.occurrenceCount) == [1])

        feature.show("Saved")
        #expect(feature.activeNotifications.map(\.message) == ["Saved"])
        #expect(feature.activeNotifications.map(\.occurrenceCount) == [2])
        #expect(feature.notifications.map(\.occurrenceCount) == [2])
    }

    @Test
    func mergedMessageSuffixAppearsFromTheSecondOccurrence() throws {
        let english = Locale(identifier: "en")
        #expect(WorkbenchNotificationPresentation.message("Saved", occurrenceCount: 1, locale: english) == "Saved")
        #expect(WorkbenchNotificationPresentation.message("Saved", occurrenceCount: 2, locale: english) == "Saved (2)")
        #expect(WorkbenchNotificationPresentation.message("Saved", occurrenceCount: 12, locale: english) == "Saved (12)")

        // The shipped Simplified Chinese translation keeps the full-width
        // parentheses and must expose the same two format arguments, resolved
        // through the production formatter rather than a hand-rolled format.
        #expect(WorkbenchNotificationPresentation.message("已保存", occurrenceCount: 2,
            locale: Locale(identifier: "zh-Hans"), bundle: try notificationResourceBundle("zh-Hans"))
            == "已保存（2）")
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func balloonRendersTheMergedOccurrenceCount(scheme: ColorScheme) throws {
        MacBundledFontRegistry.registerFonts()
        let captureDirectory = ProcessInfo.processInfo.environment["LITHE_NOTIFICATION_CAPTURE_DIR"]

        func rasterize(_ occurrenceCount: Int, message: String, language: String,
                       bundle: Bundle) throws -> Data {
            let host = NSHostingView(rootView: WorkbenchNotificationBanner(
                message: message, occurrenceCount: occurrenceCount,
                bundle: bundle, dismiss: {})
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: language)))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }

        let chineseMessage = "构建失败：无法解析依赖"
        let chineseBundle = try notificationResourceBundle("zh-Hans")
        func renderChinese(_ occurrenceCount: Int, bundle: Bundle? = nil) throws -> Data {
            try rasterize(occurrenceCount, message: chineseMessage, language: "zh-Hans",
                          bundle: bundle ?? chineseBundle)
        }

        // The merged count must reach the balloon itself, so the same message
        // rendered with a count cannot have the same pixels as rendering it
        // alone. A dropped `occurrenceCount` at the call site fails here.
        let single = try renderChinese(1)
        let counted = try renderChinese(2)
        #expect(single != counted, "The merged occurrence count never reached the balloon")

        // The shipped Simplified Chinese suffix must reach the balloon too, not
        // only the formatter: the same message under the English format differs
        // exactly in those parentheses.
        let halfWidthSuffix = try renderChinese(2, bundle: try notificationResourceBundle("en"))
        #expect(counted != halfWidthSuffix,
                "The shipped Simplified Chinese count suffix never reached the balloon")

        guard let captureDirectory else { return }
        let theme = scheme == .dark ? "dark" : "light"
        for (language, message) in [("zh-Hans", chineseMessage),
                                    ("en", "Build failed: cannot resolve dependencies")] {
            let bundle = try notificationResourceBundle(language)
            for count in [2, 3] {
                try rasterize(count, message: message, language: language, bundle: bundle).write(
                    to: URL(fileURLWithPath: captureDirectory).appendingPathComponent(
                        "notification-merged-\(language)-\(theme)-\(count).png"))
            }
        }
    }

    /// The shipped localization bundle for one language, so a captured or
    /// asserted notification renders real translations instead of format keys.
    private func notificationResourceBundle(_ language: String) throws -> Bundle {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        return try #require(Bundle(url: resources.appendingPathComponent("\(language).lproj")))
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

    /// Time left on every registered dismissal, measured from the clock's now.
    var pendingRemaining: [Duration] {
        pending.values.map { now.duration(to: $0.deadline) }
    }

    func releaseAll() { pending.values.forEach { $0.gate.open() } }

    func settle(_ label: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock().now < deadline { await Task.yield() }
        #expect(condition(), "Notification task did not reach the \(label) clock boundary")
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
