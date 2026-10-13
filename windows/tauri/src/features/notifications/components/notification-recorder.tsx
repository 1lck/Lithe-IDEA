import { useEffect, useRef } from "react";
import { useSonner } from "sonner";
import type { NotificationType } from "../types/notifications.types";
import { partitionNewOccurrences } from "../utils/notification-occurrences";
import { useNotificationsStore, type NotificationReport } from "../stores/notifications.store";

function getNotificationType(type: string | undefined): NotificationType {
  if (type === "success" || type === "warning" || type === "error") return type;
  return "info";
}

export function NotificationRecorder() {
  const { toasts } = useSonner();
  const record = useNotificationsStore((state) => state.actions.record);
  // Sonner keeps the visible toasts in one array and this effect re-runs on
  // every change, so each toast is reported once per appearance. Reporting a
  // toast again would otherwise look like repeated content and inflate the
  // merged occurrence count of a notification that never appeared twice.
  const reportedToastIds = useRef<Set<string>>(new Set());

  useEffect(() => {
    const reports: NotificationReport[] = [];

    for (const toast of toasts) {
      if ("dismiss" in toast || typeof toast.title !== "string") continue;

      reports.push({
        id: String(toast.id),
        message: toast.title,
        description: typeof toast.description === "string" ? toast.description : undefined,
        type: getNotificationType(toast.type),
      });
    }

    const occurrences = partitionNewOccurrences(
      reportedToastIds.current,
      reports.map((report) => report.id),
    );
    reportedToastIds.current = occurrences.reportedIds;

    for (const report of reports) {
      record({ ...report, isNewOccurrence: occurrences.newIds.has(report.id) });
    }
  }, [record, toasts]);

  return null;
}
