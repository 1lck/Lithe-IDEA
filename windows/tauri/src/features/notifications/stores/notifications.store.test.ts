import { beforeEach, describe, expect, test } from "bun:test";
import { useNotificationsStore } from "./notifications.store";

const actions = () => useNotificationsStore.getState().actions;
const notifications = () => useNotificationsStore.getState().notifications;
const messages = () => notifications().map((item) => item.message);

describe("notifications store", () => {
  beforeEach(() => {
    actions().clear();
  });

  test("keeps one entry and counts repeated content", () => {
    actions().record({ id: "toast-1", message: "Build failed", type: "error" });
    expect(notifications()).toHaveLength(1);
    expect(notifications()[0]).toMatchObject({ message: "Build failed", count: 1 });
    const rowID = notifications()[0].id;

    actions().record({ id: "toast-2", message: "Build failed", type: "error" });
    expect(notifications()).toHaveLength(1);
    expect(notifications()[0]).toMatchObject({
      id: rowID,
      message: "Build failed",
      count: 2,
      read: false,
    });

    actions().record({ id: "toast-3", message: "Build failed", type: "error" });
    expect(notifications()).toHaveLength(1);
    expect(notifications()[0].count).toBe(3);
  });

  test("counts a source that disappears and returns", () => {
    // A fixed toast key can be dismissed and shown again. `partitionNewOccurrences`
    // reports that second appearance as new, so the store must count it even
    // though the source id is the same one as before.
    actions().record({
      id: "toast-1",
      message: "Build failed",
      type: "error",
      isNewOccurrence: true,
    });
    expect(notifications()[0].count).toBe(1);

    actions().record({
      id: "toast-1",
      message: "Build failed",
      type: "error",
      isNewOccurrence: true,
    });
    expect(notifications()).toHaveLength(1);
    expect(notifications()[0].count).toBe(2);

    // Re-reporting that same appearance while it stays visible still counts once.
    actions().record({
      id: "toast-1",
      message: "Build failed",
      type: "error",
      isNewOccurrence: false,
    });
    expect(notifications()[0].count).toBe(2);
  });

  test("re-reporting a visible notification never raises the count", () => {
    // The recorder re-reports every toast that is still on screen whenever the
    // toast list changes, so only a genuinely new appearance may count up.
    actions().record({ id: "toast-1", message: "Build failed", type: "error" });
    actions().record({ id: "toast-2", message: "Build failed", type: "error" });
    expect(notifications()[0].count).toBe(2);

    actions().record({
      id: "toast-1",
      message: "Build failed",
      type: "error",
      isNewOccurrence: false,
    });
    actions().record({
      id: "toast-2",
      message: "Build failed",
      type: "error",
      isNewOccurrence: false,
    });

    expect(notifications()).toHaveLength(1);
    expect(notifications()[0].count).toBe(2);
  });

  test("moves only the updated source's occurrences to the new content", () => {
    // Two sources merged into "Build failed" (2). Updating one of them must not
    // carry the group's count onto text that has appeared only once.
    actions().record({ id: "toast-1", message: "Build failed", type: "error" });
    actions().record({ id: "toast-2", message: "Build failed", type: "error" });
    expect(notifications()[0].count).toBe(2);

    actions().record({
      id: "toast-1",
      message: "Build timed out",
      type: "error",
      isNewOccurrence: false,
    });
    actions().record({
      id: "toast-2",
      message: "Build failed",
      type: "error",
      isNewOccurrence: false,
    });

    expect(messages().sort()).toEqual(["Build failed", "Build timed out"]);
    expect(notifications().find((item) => item.message === "Build timed out")?.count).toBe(1);
    expect(notifications().find((item) => item.message === "Build failed")?.count).toBe(1);
  });

  test("merges an updated source into the content it moved to", () => {
    actions().record({ id: "toast-1", message: "Connecting", type: "info" });
    actions().record({ id: "toast-2", message: "Connected", type: "success" });

    actions().record({
      id: "toast-1",
      message: "Connected",
      type: "success",
      isNewOccurrence: false,
    });

    // The old content loses its only source, the new content keeps the
    // occurrences of the source that has always reported it.
    expect(messages()).toEqual(["Connected"]);
    expect(notifications()[0].count).toBe(2);
  });

  test("never merges notifications with different content", () => {
    actions().record({ id: "toast-1", message: "Build failed", type: "error" });
    actions().record({ id: "toast-2", message: "Build failed", type: "warning" });
    actions().record({ id: "toast-3", message: "Build failed", description: "Java", type: "error" });
    actions().record({ id: "toast-4", message: "Tests passed", type: "error" });

    expect(
      notifications().map((item) => [item.type, item.message, item.description, item.count]),
    ).toEqual([
      ["error", "Tests passed", undefined, 1],
      ["error", "Build failed", "Java", 1],
      ["warning", "Build failed", undefined, 1],
      ["error", "Build failed", undefined, 1],
    ]);
  });

  test("keeps row identity stable while sources merge into it", () => {
    actions().record({ id: "toast-1", message: "Build failed", type: "error" });
    const rowID = notifications()[0].id;

    actions().record({ id: "toast-2", message: "Build failed", type: "error" });
    actions().record({
      id: "toast-2",
      message: "Build failed",
      type: "error",
      isNewOccurrence: false,
    });

    expect(notifications()[0].id).toBe(rowID);
    expect(notifications()[0].count).toBe(2);
  });

  test("a repeated notification returns to the front as unread", () => {
    actions().record({ id: "toast-1", message: "Build failed", type: "error" });
    actions().record({ id: "toast-2", message: "Tests passed", type: "success" });
    actions().markAllRead();
    expect(notifications().every((item) => item.read)).toBe(true);

    actions().record({ id: "toast-3", message: "Build failed", type: "error" });

    expect(messages()).toEqual(["Build failed", "Tests passed"]);
    expect(notifications()[0]).toMatchObject({ count: 2, read: false });
    expect(notifications()[0].updatedAt).toBeGreaterThanOrEqual(notifications()[0].createdAt);
  });
});
