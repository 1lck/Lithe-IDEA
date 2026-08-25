import { expect, test } from "bun:test";
import { getSidebarPaneLevel } from "./sidebar-pane-utils";

test("notifications belong to the edge tool window rail", () => {
  expect(getSidebarPaneLevel("notifications")).toBe("edge");
});
