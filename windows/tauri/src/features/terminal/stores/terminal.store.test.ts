import { expect, test } from "bun:test";
import { createTerminalStore } from "./terminal.store";

test("bottom pane spans the full workbench width by default like IDEA", () => {
  expect(createTerminalStore().getState().widthMode).toBe("full");
});

test("width mode can still be switched to editor width", () => {
  const store = createTerminalStore();
  store.getState().actions.setWidthMode("editor");
  expect(store.getState().widthMode).toBe("editor");
});
