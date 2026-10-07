import type { NotificationEntry } from "@/features/notifications/types/notifications.types";
import { formatCalendarDateGroup, formatCompactRelativeDate } from "@/utils/date";

/** The subset of `useTranslation().t` the notification formatters need. */
export type NotificationTranslator = (
  key: string,
  values?: Record<string, string | number>,
) => string;

export function formatNotificationAge(timestamp: number) {
  return formatCompactRelativeDate(timestamp, {
    afterWeek: "days",
    capitalizeJustNow: true,
  });
}

/**
 * Renders the notification text, appending the accumulated occurrence count
 * once the same content has been reported more than once.
 */
export function formatNotificationMessage(
  notification: Pick<NotificationEntry, "message" | "count">,
  translate: NotificationTranslator,
) {
  if (notification.count <= 1) return notification.message;

  return translate("notifications.occurrenceCount", {
    message: notification.message,
    count: notification.count,
  });
}

export function formatNotificationText(
  notification: NotificationEntry,
  translate: NotificationTranslator,
) {
  return [
    formatNotificationMessage(notification, translate),
    notification.description,
    `${notification.type} - ${formatNotificationAge(notification.updatedAt)}`,
  ]
    .filter(Boolean)
    .join("\n\n");
}

export function formatNotificationGroupDate(timestamp: number) {
  return formatCalendarDateGroup(timestamp);
}
