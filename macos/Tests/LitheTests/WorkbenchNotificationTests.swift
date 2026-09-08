import Foundation
import Testing
@testable import Lithe

@Suite("Workbench notifications")
@MainActor
struct WorkbenchNotificationTests {
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

        model.setNotificationStackHovered(true)
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

private final class WorkbenchNotificationTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
