import Combine
import Foundation

private enum WorkbenchNotificationTiming {
    // NotificationsManagerImpl's ordinary balloon timeout (Community New UI).
    static let displayDuration: Duration = .seconds(10)
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
    private var hoveredIDs: Set<UUID> = []
    private var isApplicationActive = true
    private let now: () -> ContinuousClock.Instant
    private let sleep: (Duration) async throws -> Void

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now
        self.sleep = sleep
    }

    deinit {
        dismissalTasks.values.forEach { $0.cancel() }
    }

    func show(_ message: String) {
        // A recurring message merges into the row it already owns: the entry
        // stays in place, only its occurrence count grows. Without this, a
        // message repeated by a background workflow floods the center.
        if let index = notifications.firstIndex(where: { $0.message == message }) {
            notifications[index].occurrenceCount += 1
            notifications[index].updatedAt = Date()
            notifications[index].isRead = false
            let notification = notifications.remove(at: index)
            notifications.insert(notification, at: 0)
            presentOrRefresh(notification)
            return
        }

        let notification = WorkbenchNotification(message: message)
        notifications.insert(notification, at: 0)
        if notifications.count > WorkbenchNotificationTiming.maximumHistoryCount {
            notifications.removeLast(
                notifications.count - WorkbenchNotificationTiming.maximumHistoryCount
            )
        }

        present(notification)
    }

    /// Adds a balloon for a notification that has none yet, applying the
    /// visible-count limit and its overflow affordance.
    private func present(_ notification: WorkbenchNotification) {
        activeNotifications.append(notification)
        if activeNotifications.count > WorkbenchNotificationTiming.maximumVisibleCount {
            let removed = activeNotifications.removeFirst()
            cancelDismissal(for: removed.id)
            // All current Lithe messages are timeline notifications. Like
            // ActionCenterBalloonLayout, attach overflow to the oldest survivor.
            activeNotifications[0].collapsedCount = min(removed.collapsedCount + 1,
                notifications.count - activeNotifications.count)
        }

        scheduleDismissal(for: notification, after: WorkbenchNotificationTiming.displayDuration)
    }

    /// Re-surfaces a notification that already owns a balloon, or presents one.
    ///
    /// A repeated message restarts its own display window and moves to the top
    /// of the stack instead of leaving the earlier deadline running.
    private func presentOrRefresh(_ notification: WorkbenchNotification) {
        guard let index = activeNotifications.firstIndex(where: { $0.id == notification.id }) else {
            present(notification)
            return
        }
        // Overflow is a stack-level affordance, not history: the history copy
        // never carries `collapsedCount`, so hand the balloon's own count to the
        // oldest survivor the same way `present` does.
        let refreshed = activeNotifications.remove(at: index)
        activeNotifications.append(notification)
        if refreshed.collapsedCount > 0 {
            activeNotifications[0].collapsedCount = min(
                activeNotifications[0].collapsedCount + refreshed.collapsedCount,
                notifications.count - activeNotifications.count)
        }
        scheduleDismissal(for: notification, after: WorkbenchNotificationTiming.displayDuration)
    }

    func setHovered(_ id: UUID, isHovered: Bool) {
        guard let notification = activeNotifications.first(where: { $0.id == id }),
              hoveredIDs.contains(id) != isHovered else { return }
        if isHovered { hoveredIDs.insert(id); pauseDismissal(id) }
        else { hoveredIDs.remove(id); resumeDismissal(notification) }
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else { return }
        isApplicationActive = isActive
        for notification in activeNotifications {
            if isActive { resumeDismissal(notification) }
            else { pauseDismissal(notification.id) }
        }
    }

    private func pauseDismissal(_ id: UUID) {
        if let deadline = dismissalDeadlines.removeValue(forKey: id) {
            let instant = now()
            remainingDurations[id] = instant < deadline ? instant.duration(to: deadline) : .zero
        }
        dismissalTasks.removeValue(forKey: id)?.cancel()
    }

    private func resumeDismissal(_ notification: WorkbenchNotification) {
        guard isApplicationActive, !hoveredIDs.contains(notification.id),
              let remaining = remainingDurations.removeValue(forKey: notification.id) else { return }
        scheduleDismissal(for: notification, after: remaining)
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
        dismissAll()
    }

    /// Closing balloons never deletes the notification-center history.
    func dismissAll() {
        activeNotifications.removeAll()
        dismissalTasks.values.forEach { $0.cancel() }
        dismissalTasks.removeAll()
        dismissalDeadlines.removeAll()
        remainingDurations.removeAll()
        hoveredIDs.removeAll()
    }

    private func scheduleDismissal(
        for notification: WorkbenchNotification,
        after duration: Duration
    ) {
        dismissalTasks[notification.id]?.cancel()
        guard isApplicationActive, !hoveredIDs.contains(notification.id) else {
            remainingDurations[notification.id] = duration
            return
        }
        let deadline = now().advanced(by: duration)
        dismissalDeadlines[notification.id] = deadline
        let sleep = self.sleep
        dismissalTasks[notification.id] = Task { @MainActor [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.isApplicationActive, !self.hoveredIDs.contains(notification.id),
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
        hoveredIDs.remove(id)
    }
}
