import Foundation

extension AppModel {
    func showNotification(_ message: String) {
        let notification = WorkbenchNotification(message: message)
        notifications.insert(notification, at: 0)
        if notifications.count > 100 {
            notifications.removeLast(notifications.count - 100)
        }
        notificationMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.notifications.first?.id == notification.id,
               self?.notificationMessage == message {
                self?.notificationMessage = nil
            }
        }
    }

    func markAllNotificationsRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clearNotifications() {
        notifications.removeAll()
        notificationMessage = nil
    }
}
