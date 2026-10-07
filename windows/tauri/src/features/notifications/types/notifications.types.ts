import type { ReactNode } from "react";

export type NotificationType = "info" | "success" | "warning" | "error";

/** One notification source (a toast) and how often it contributed to a row. */
export type NotificationSourceUsage = [id: string, occurrences: number];

export interface NotificationEntry {
  id: string;
  message: string;
  description?: string;
  type: NotificationType;
  createdAt: number;
  updatedAt: number;
  read: boolean;
  /**
   * How often the same content has been reported. The first report is 1; later
   * reports raise this count instead of adding a duplicate entry.
   */
  count: number;
  /**
   * Sources merged into this row, most recently reported last. A row is
   * identified by its content, so this bookkeeping is what lets one source move
   * its own occurrences when its text changes. It is bounded: a source evicted
   * past the bound stays inside `count` but can no longer move.
   */
  sources: NotificationSourceUsage[];
}

export interface ToastInput {
  key?: string;
  message: string;
  description?: string;
  type: NotificationType;
  duration?: number;
  icon?: ReactNode;
  action?: {
    label: string;
    onClick: () => void;
  };
}

export type NotificationFilter = "all" | NotificationEntry["type"];

export type NotificationItemAction = {
  id: string;
  label: string;
  icon: ReactNode;
  onSelect: () => void;
  variant?: "default" | "danger";
};
