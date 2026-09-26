import { expect, test } from "bun:test";
import { resolveUsageToolWindowUpdate } from "./usage-tool-window-actions";

test("open selects and shows the usage tool window", () => {
  expect(
    resolveUsageToolWindowUpdate(
      { activeRightSidebarView: "outline", isRightSidebarVisible: false },
      "open",
    ),
  ).toEqual({
    activeRightSidebarView: "usage",
    isRightSidebarVisible: true,
  });
});

test("toggle closes the active usage tool window", () => {
  expect(
    resolveUsageToolWindowUpdate(
      { activeRightSidebarView: "usage", isRightSidebarVisible: true },
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "usage",
    isRightSidebarVisible: false,
  });
});

test("toggle switches from another right tool window to usage", () => {
  expect(
    resolveUsageToolWindowUpdate(
      { activeRightSidebarView: "notifications", isRightSidebarVisible: true },
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "usage",
    isRightSidebarVisible: true,
  });
});

test("close on another view leaves the right tool window alone", () => {
  expect(
    resolveUsageToolWindowUpdate(
      { activeRightSidebarView: "outline", isRightSidebarVisible: true },
      "close",
    ),
  ).toEqual({
    activeRightSidebarView: "outline",
    isRightSidebarVisible: true,
  });
});