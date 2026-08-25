import { expect, test } from "bun:test";
import { getProjectTabBarItems, shouldShowProjectTabBar } from "./project-tab-bar-model";

test("preserves project order and exposes one active tab", () => {
  const result = getProjectTabBarItems([
    { id: "a", name: "Alpha", path: "D:/alpha", isActive: true, lastOpened: 1 },
    { id: "b", name: "Beta", path: "D:/beta", isActive: true, lastOpened: 2 },
  ]);

  expect(result.map((tab) => tab.name)).toEqual(["Alpha", "Beta"]);
  expect(result.map((tab) => tab.isActive)).toEqual([true, false]);
});

test("shows the project tab row only when it has useful switching value", () => {
  expect(shouldShowProjectTabBar(0, true)).toBe(false);
  expect(shouldShowProjectTabBar(1, true)).toBe(false);
  expect(shouldShowProjectTabBar(2, true)).toBe(true);
  expect(shouldShowProjectTabBar(1, false)).toBe(true);
});
