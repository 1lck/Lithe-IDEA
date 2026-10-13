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

    func setNotificationHovered(_ id: UUID, isHovered: Bool) {
        notificationFeature.setHovered(id, isHovered: isHovered)
    }

    func setNotificationsApplicationActive(_ isActive: Bool) {
        notificationFeature.setApplicationActive(isActive)
    }

    func dismissNotificationBalloons() {
        notificationFeature.dismissAll()
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
