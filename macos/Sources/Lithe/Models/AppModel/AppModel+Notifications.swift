import Foundation

extension AppModel {
    var activeNotifications: [WorkbenchNotification] {
        notificationFeature.activeNotifications
    }

    var notifications: [WorkbenchNotification] {
        notificationFeature.notifications
    }

    func showNotification(_ message: String) {
        notificationFeature.show(message)
    }

    func setNotificationStackHovered(_ isHovered: Bool) {
        notificationFeature.setHovered(isHovered)
    }

    func dismissNotification(_ id: UUID) {
        notificationFeature.dismiss(id)
    }

    func markAllNotificationsRead() {
        notificationFeature.markAllRead()
    }

    func clearNotifications() {
        notificationFeature.clear()
    }
}
