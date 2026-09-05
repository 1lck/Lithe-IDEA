import Foundation

private enum WorkbenchNotificationTiming {
    static let displayDuration: Duration = .seconds(4)
    static let maximumVisibleCount = 3
}

extension AppModel {
    func showNotification(_ message: String) {
        let notification = WorkbenchNotification(message: message)
        notifications.insert(notification, at: 0)
        if notifications.count > 100 {
            notifications.removeLast(notifications.count - 100)
        }

        activeNotifications.append(notification)
        if activeNotifications.count > WorkbenchNotificationTiming.maximumVisibleCount {
            let removed = activeNotifications.removeFirst()
            cancelNotificationDismissal(for: removed.id)
        }
        if areNotificationsHovered {
            notificationRemainingDurations[notification.id] = WorkbenchNotificationTiming.displayDuration
        } else {
            scheduleNotificationDismissal(
                for: notification,
                after: WorkbenchNotificationTiming.displayDuration
            )
        }
    }

    func setNotificationStackHovered(_ isHovered: Bool) {
        guard areNotificationsHovered != isHovered else { return }
        areNotificationsHovered = isHovered

        if isHovered {
            let now = ContinuousClock().now
            for notification in activeNotifications {
                if let deadline = notificationDismissalDeadlines.removeValue(forKey: notification.id) {
                    notificationRemainingDurations[notification.id] = now < deadline
                        ? now.duration(to: deadline)
                        : .zero
                }
                notificationDismissalTasks.removeValue(forKey: notification.id)?.cancel()
            }
        } else {
            for notification in activeNotifications {
                let remaining = notificationRemainingDurations.removeValue(forKey: notification.id)
                    ?? WorkbenchNotificationTiming.displayDuration
                scheduleNotificationDismissal(for: notification, after: remaining)
            }
        }
    }

    func dismissNotification(_ id: UUID) {
        guard activeNotifications.contains(where: { $0.id == id }) else { return }
        activeNotifications.removeAll { $0.id == id }
        cancelNotificationDismissal(for: id)
    }

    func markAllNotificationsRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clearNotifications() {
        notifications.removeAll()
        activeNotifications.removeAll()
        for task in notificationDismissalTasks.values {
            task.cancel()
        }
        notificationDismissalTasks.removeAll()
        notificationDismissalDeadlines.removeAll()
        notificationRemainingDurations.removeAll()
        areNotificationsHovered = false
    }

    private func scheduleNotificationDismissal(
        for notification: WorkbenchNotification,
        after duration: Duration
    ) {
        notificationDismissalTasks[notification.id]?.cancel()
        let deadline = ContinuousClock().now.advanced(by: duration)
        notificationDismissalDeadlines[notification.id] = deadline
        notificationDismissalTasks[notification.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  !self.areNotificationsHovered,
                  self.notificationDismissalDeadlines[notification.id] == deadline else { return }
            self.dismissNotification(notification.id)
        }
    }

    private func cancelNotificationDismissal(for id: UUID) {
        notificationDismissalTasks.removeValue(forKey: id)?.cancel()
        notificationDismissalDeadlines.removeValue(forKey: id)
        notificationRemainingDurations.removeValue(forKey: id)
    }
}
