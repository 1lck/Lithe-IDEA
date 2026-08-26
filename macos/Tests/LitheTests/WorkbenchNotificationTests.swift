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

        model.markAllNotificationsRead()
        #expect(model.notifications.allSatisfy { $0.isRead })

        model.clearNotifications()
        #expect(model.notifications.isEmpty)
        #expect(model.notificationMessage == nil)
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
