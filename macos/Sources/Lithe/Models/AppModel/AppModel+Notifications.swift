import Foundation
import LitheModuleAPI

extension AppModel {
    var activeNotifications: [WorkbenchNotification] {
        notificationFeature.activeNotifications
    }

    var notifications: [WorkbenchNotification] {
        notificationFeature.notifications
    }

    func showNotification(_ message: String, arguments: [String] = [],
                          action: WorkbenchNotification.Action? = nil, logReference: LogRecordReference? = nil) {
        notificationFeature.show(message, arguments: arguments, action: action, logReference: logReference)
    }

    /// Records the failure at the boundary that decides to notify the user.
    func notificationFailure(_ error: Error, operation: String) -> LogRecordReference? {
        guard !error.isCancellation, let sink = services.logSink else { return nil }
        return LogScope(sink: sink).emitReferenced(AppNotificationOperationFailed(error: error, operation: operation))
    }

    func notificationRejection(operation: String, reason: String) -> LogRecordReference? {
        guard let sink = services.logSink else { return nil }
        return LogScope(sink: sink).emitReferenced(AppNotificationOperationRejected(operation: operation, reason: reason))
    }

    func showNotificationLog(_ id: UUID) { notificationFeature.showLog(id) }

    func performNotificationAction(_ id: UUID) {
        guard let action = notificationFeature.notifications.first(where: { $0.id == id })?.action else { return }
        UserActionTrace.run(action.id, surface: .notification, sink: services.logSink) { notificationFeature.perform(id) }
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
