import { expect, test } from "bun:test";
import { resolveRightToolWindowUpdate } from "./right-tool-window-actions";

test("toggle opens the requested right tool window", () => {
  expect(
    resolveRightToolWindowUpdate(
      { activeRightSidebarView: "outline", isRightSidebarVisible: false },
      "maven",
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "maven",
    isRightSidebarVisible: true,
  });
});

test("toggle closes the active right tool window", () => {
  expect(
    resolveRightToolWindowUpdate(
      { activeRightSidebarView: "maven", isRightSidebarVisible: true },
      "maven",
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "maven",
    isRightSidebarVisible: false,
  });
});

test("toggle switches between right tool windows", () => {
  expect(
    resolveRightToolWindowUpdate(
      { activeRightSidebarView: "notifications", isRightSidebarVisible: true },
      "maven",
      "toggle",
    ),
  ).toEqual({
    activeRightSidebarView: "maven",
    isRightSidebarVisible: true,
  });
});

test("close only hides the requested right tool window", () => {
  expect(
    resolveRightToolWindowUpdate(
      { activeRightSidebarView: "maven", isRightSidebarVisible: true },
      "maven",
      "close",
    ),
  ).toEqual({
    activeRightSidebarView: "maven",
    isRightSidebarVisible: false,
  });

  expect(
    resolveRightToolWindowUpdate(
      { activeRightSidebarView: "notifications", isRightSidebarVisible: true },
      "maven",
      "close",
    ),
  ).toEqual({
    activeRightSidebarView: "notifications",
    isRightSidebarVisible: true,
  });
});
