import Combine
import Foundation

private enum WorkbenchNotificationTiming {
    static let displayDuration: Duration = .seconds(4)
    static let maximumVisibleCount = 3
    static let maximumHistoryCount = 100
}

/// Owns the workbench notification history and transient presentation queue.
///
/// Feature models publish notification state so the application shell only
/// forwards compatibility calls and relays changes to legacy observers.
@MainActor
final class WorkbenchNotificationFeatureModel: ObservableObject {
    @Published private(set) var activeNotifications: [WorkbenchNotification] = []
    @Published private(set) var notifications: [WorkbenchNotification] = []

    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]
    private var dismissalDeadlines: [UUID: ContinuousClock.Instant] = [:]
    private var remainingDurations: [UUID: Duration] = [:]
    private(set) var isHovered = false

    deinit {
        dismissalTasks.values.forEach { $0.cancel() }
    }

    func show(_ message: String) {
        let notification = WorkbenchNotification(message: message)
        notifications.insert(notification, at: 0)
        if notifications.count > WorkbenchNotificationTiming.maximumHistoryCount {
            notifications.removeLast(
                notifications.count - WorkbenchNotificationTiming.maximumHistoryCount
            )
        }

        activeNotifications.append(notification)
        if activeNotifications.count > WorkbenchNotificationTiming.maximumVisibleCount {
            let removed = activeNotifications.removeFirst()
            cancelDismissal(for: removed.id)
        }

        if isHovered {
            remainingDurations[notification.id] = WorkbenchNotificationTiming.displayDuration
        } else {
            scheduleDismissal(
                for: notification,
                after: WorkbenchNotificationTiming.displayDuration
            )
        }
    }

    func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else { return }
        self.isHovered = isHovered

        if isHovered {
            let now = ContinuousClock().now
            for notification in activeNotifications {
                if let deadline = dismissalDeadlines.removeValue(forKey: notification.id) {
                    remainingDurations[notification.id] = now < deadline
                        ? now.duration(to: deadline)
                        : .zero
                }
                dismissalTasks.removeValue(forKey: notification.id)?.cancel()
            }
        } else {
            for notification in activeNotifications {
                let remaining = remainingDurations.removeValue(forKey: notification.id)
                    ?? WorkbenchNotificationTiming.displayDuration
                scheduleDismissal(for: notification, after: remaining)
            }
        }
    }

    func dismiss(_ id: UUID) {
        guard activeNotifications.contains(where: { $0.id == id }) else { return }
        activeNotifications.removeAll { $0.id == id }
        cancelDismissal(for: id)
    }

    func markAllRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clear() {
        notifications.removeAll()
        activeNotifications.removeAll()
        dismissalTasks.values.forEach { $0.cancel() }
        dismissalTasks.removeAll()
        dismissalDeadlines.removeAll()
        remainingDurations.removeAll()
        isHovered = false
    }

    private func scheduleDismissal(
        for notification: WorkbenchNotification,
        after duration: Duration
    ) {
        dismissalTasks[notification.id]?.cancel()
        let deadline = ContinuousClock().now.advanced(by: duration)
        dismissalDeadlines[notification.id] = deadline
        dismissalTasks[notification.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  !self.isHovered,
                  self.dismissalDeadlines[notification.id] == deadline else {
                return
            }
            self.dismiss(notification.id)
        }
    }

    private func cancelDismissal(for id: UUID) {
        dismissalTasks.removeValue(forKey: id)?.cancel()
        dismissalDeadlines.removeValue(forKey: id)
        remainingDurations.removeValue(forKey: id)
    }
}
