import { expect, test } from "bun:test";
import { resolveNotificationsToolWindowUpdate } from "./notifications-tool-window-actions";

test("open selects and shows the notifications tool window", () => {
  expect(
    resolveNotificationsToolWindowUpdate(
      { activeRightSidebarView: "outline", isRightSidebarVisible: false },
      "open",
    ),
  ).toEqual({
    activeRightSidebarView: "notifications",
    isRightSidebarVisible: true,
  });
});

test("toggle closes the active notifications tool window", () => {
  expect(
    resolveNotificationsToolWindowUpdate(
      { activeRightSidebarView: "notifications", isRightSidebarVisible: true },
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "notifications",
    isRightSidebarVisible: false,
  });
});

test("toggle switches from another right tool window to notifications", () => {
  expect(
    resolveNotificationsToolWindowUpdate(
      { activeRightSidebarView: "outline", isRightSidebarVisible: true },
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "notifications",
    isRightSidebarVisible: true,
  });
});

test("close hides the right tool window", () => {
  expect(
    resolveNotificationsToolWindowUpdate(
      { activeRightSidebarView: "notifications", isRightSidebarVisible: true },
      "close",
    ),
  ).toEqual({
    activeRightSidebarView: "notifications",
    isRightSidebarVisible: false,
  });
});
