import { create } from "zustand";
import type {
  NotificationEntry,
  NotificationSourceUsage,
  NotificationType,
} from "../types/notifications.types";
import { createSelectors } from "@/utils/zustand-selectors";

const MAX_NOTIFICATIONS = 20;
/**
 * Sources tracked per row. A source evicted past this bound keeps its
 * occurrences inside the row's `count`; it only loses the ability to move them
 * to another content group later.
 */
const MAX_TRACKED_SOURCES = 24;

/**
 * A report of one notification source, such as a single toast.
 *
 * `isNewOccurrence` separates "the same source reported itself again" from
 * "the same content appeared again": the recorder re-reports every toast that
 * is still on screen whenever the toast list changes, and only a genuinely new
 * appearance may raise the merged occurrence count.
 */
export interface NotificationReport {
  id: string;
  message: string;
  description?: string;
  type: NotificationType;
  isNewOccurrence?: boolean;
}

interface NotificationsState {
  notifications: NotificationEntry[];
  actions: {
    record: (notification: NotificationReport) => void;
    markAllRead: () => void;
    remove: (id: string) => void;
    clear: () => void;
  };
}

/** Notification content is the merge key: identical text stays one row. */
function contentKey(item: Pick<NotificationEntry, "type" | "message" | "description">) {
  return `${item.type}\u0000${item.message}\u0000${item.description ?? ""}`;
}

/**
 * Row identity derived from content. Rows merge by content and a row's content
 * never changes, because a source that changes its text moves to another row.
 * Keeping row identity apart from source identity is what stops a source update
 * from carrying a whole merged group's count onto different text.
 */
function rowID(item: Pick<NotificationEntry, "type" | "message" | "description">) {
  const key = contentKey(item);
  let hash = 2166136261;

  for (let index = 0; index < key.length; index += 1) {
    hash ^= key.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }

  return `notification-${(hash >>> 0).toString(16)}`;
}

/** Occurrences a source already contributed to a row, when it is still tracked. */
function trackedOccurrences(sources: NotificationSourceUsage[], id: string) {
  return sources.find(([sourceID]) => sourceID === id)?.[1];
}

/** Records a source against a row, keeping only the most recent sources. */
function trackSource(sources: NotificationSourceUsage[], id: string, occurrences: number) {
  const next = sources.filter(([sourceID]) => sourceID !== id);
  next.push([id, occurrences]);

  return next.length > MAX_TRACKED_SOURCES ? next.slice(-MAX_TRACKED_SOURCES) : next;
}

/** Drops a row whose last source moved away, or applies the reduced contribution. */
function releaseSource(
  notifications: NotificationEntry[],
  entry: NotificationEntry,
  sourceID: string,
) {
  const sources = entry.sources.filter(([id]) => id !== sourceID);
  const count = entry.count - (trackedOccurrences(entry.sources, sourceID) ?? 0);

  if (count <= 0) return notifications.filter((item) => item.id !== entry.id);
  return notifications.map((item) => (item.id === entry.id ? { ...item, count, sources } : item));
}

/** Moves a merged row to the front and keeps the retained-row limit. */
function promote(notifications: NotificationEntry[], entry: NotificationEntry) {
  return [entry, ...notifications.filter((item) => item.id !== entry.id)].slice(0, MAX_NOTIFICATIONS);
}

export const useNotificationsStore = createSelectors(
  create<NotificationsState>()((set) => ({
    notifications: [],
    actions: {
      record: (notification) =>
        set((state) => {
          const { isNewOccurrence, ...reported } = notification;
          const now = Date.now();
          let occurrences = isNewOccurrence === false ? 0 : 1;

          // A source that changes its own text takes its occurrences out of the
          // row it contributed to before joining the row matching the new text.
          let notifications = state.notifications;
          const owner = notifications.find(
            (item) => trackedOccurrences(item.sources, reported.id) !== undefined,
          );

          if (owner) {
            occurrences += trackedOccurrences(owner.sources, reported.id) ?? 0;
            notifications = releaseSource(notifications, owner, reported.id);
          }

          const target = notifications.find((item) => contentKey(item) === contentKey(reported));
          const next: NotificationEntry = target
            ? {
                ...target,
                ...reported,
                id: target.id,
                count: target.count + occurrences,
                sources:
                  occurrences > 0
                    ? trackSource(target.sources, reported.id, occurrences)
                    : target.sources,
                updatedAt: now,
                read: false,
              }
            : {
                ...reported,
                id: rowID(reported),
                // A re-reported source still reappears once even when the store
                // no longer remembers it, after a removal or the retained limit.
                count: Math.max(occurrences, 1),
                sources: [[reported.id, Math.max(occurrences, 1)]],
                createdAt: now,
                updatedAt: now,
                read: false,
              };

          return { notifications: promote(notifications, next) };
        }),
      markAllRead: () =>
        set((state) => ({
          notifications: state.notifications.map((item) => ({ ...item, read: true })),
        })),
      remove: (id) =>
        set((state) => ({
          notifications: state.notifications.filter((item) => item.id !== id),
        })),
      clear: () => set({ notifications: [] }),
    },
  })),
);
