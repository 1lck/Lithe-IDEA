import { expect, test } from "bun:test";
import { getProjectTabBarItems } from "./project-tab-bar-model";

test("preserves project order and exposes one active tab", () => {
  const result = getProjectTabBarItems([
    { id: "a", name: "Alpha", path: "D:/alpha", isActive: true, lastOpened: 1 },
    { id: "b", name: "Beta", path: "D:/beta", isActive: true, lastOpened: 2 },
  ]);

  expect(result.map((tab) => tab.name)).toEqual(["Alpha", "Beta"]);
  expect(result.map((tab) => tab.isActive)).toEqual([true, false]);
});
