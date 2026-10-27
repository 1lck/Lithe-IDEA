import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import {
  activate,
  catalog,
  closeGates,
  closed,
  gate,
  mountMainLayout,
  opened,
  openGates,
  owners,
  prepared,
  refreshDeclarativeUI,
  removeDeclarativeUI,
  restoreDom,
  savedUi,
  setEntries,
  setHostLabel,
  terminalMounts,
  terminalUnmounts,
  ui,
} from "./native-main-layout.test-support";
import type { NativeContribution } from "./native-ui.types";
const { moveNativeContribution, nativeTriggerId, nativeViewId, useNativeDocking } =
  await import("./native-docking");
const { restoreProjectUiState } = await import("@/features/window/stores/workspace-ui-session");

afterAll(restoreDom);
function contribution(placement: string, name: string): NativeContribution {
  return {
    pluginId: `fixture.${name}`,
    packageIdentity: `bytes-${name}`,
    windowId: `fixture.${name}.window`,
    title: `Panel ${name}`,
    placement,
    order: 0,
    native: {
      schemaVersion: 1,
      id: `fixture.${name}.panel`,
      kind: "form",
      nodes: [],
      controls: [{ id: "name", kind: "input", label: `Name ${name}`, value: "initial" }],
      source: {
        buildSystemID: `fixture.${name}.build`,
        function: "fixture.load",
      },
      actions: [
        {
          id: "save",
          title: "Save",
          kind: "invoke",
          function: "fixture.save",
          requiresSelection: false,
        },
      ],
      buttons: [{ id: "save-button", label: `Save ${name}`, action: "save" }],
      toolbar: [],
      contextMenu: [],
    },
  };
}
function trigger(entry: NativeContribution) {
  const button = document.getElementById(nativeTriggerId(nativeViewId(entry))) as HTMLButtonElement;
  expect(button).not.toBeNull();
  return button;
}
function input(host: HTMLElement, name: string) {
  const field = host.querySelector(`input[aria-label="Name ${name}"]`) as HTMLInputElement;
  expect(field).not.toBeNull();
  return field;
}
function panel(host: HTMLElement, placement: string) {
  return host.querySelector(
    `[data-native-tool-window-slot="${placement}"] [data-testid="native-plugin-panel"]`,
  );
}
function edit(field: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}
function expectReleased() {
  expect([...closed].sort()).toEqual(opened.map((binding) => binding.bindingId).sort());
  expect(owners.size).toBe(0);
}

test("MainLayout catalog and production activity rail open three slots together and keep the terminal mounted", async () => {
  const entries = ["left", "bottom", "right"].map((placement) =>
    contribution(placement, placement),
  );
  const view = await mountMainLayout(entries);
  try {
    const terminal = view.host.querySelector('[data-testid="terminal-session"]');
    expect(terminal).not.toBeNull();
    expect(terminalMounts).toBe(1);
    for (const entry of entries) await act(async () => trigger(entry).click());
    expect(view.host.querySelectorAll('[data-testid="native-plugin-panel"]')).toHaveLength(3);
    for (const entry of entries) {
      const area =
        entry.placement === "left" ? "sidebar" : entry.placement === "right" ? "tools" : "panel";
      const mounted = panel(view.host, entry.placement);
      expect(mounted).not.toBeNull();
      expect(mounted!.closest(`[style*="grid-area: ${area}"]`)).not.toBeNull();
      expect(trigger(entry).closest(".lithe-plugin-activity-rail")).not.toBeNull();
      expect(trigger(entry).getAttribute("aria-pressed")).toBe("true");
    }
    expect(opened).toHaveLength(3);
    expect(prepared.map((request) => request.bindingId)).toEqual(
      opened.map((binding) => binding.bindingId),
    );
    for (const entry of entries) {
      const close = panel(view.host, entry.placement)!.querySelector(
        'button[aria-label="Close native plugin panel"]',
      ) as HTMLButtonElement;
      await act(async () => {
        close.focus();
        close.click();
      });
      expect(document.activeElement).toBe(trigger(entry));
      expect(panel(view.host, entry.placement)).toBeNull();
    }
    expect(view.host.querySelector('[data-testid="terminal-session"]')).toBe(terminal);
    expect(terminalMounts).toBe(1);
    expect(terminalUnmounts).toBe(0);
  } finally {
    await view.close();
  }
  expect(terminalUnmounts).toBe(1);
  expectReleased();
});

test("MainLayout rail moves and hides one contribution and reopens its draft without remounting terminal", async () => {
  const entry = contribution("right", "move");
  const view = await mountMainLayout([entry]);
  try {
    const terminal = view.host.querySelector('[data-testid="terminal-session"]');
    await act(async () => trigger(entry).click());
    await act(async () => edit(input(view.host, "move"), "移动草稿"));
    await act(async () =>
      trigger(entry).dispatchEvent(
        new window.MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          button: 2,
        }),
      ),
    );
    const bottom = [...document.querySelectorAll('[role="menuitem"]')].find(
      (item) => item.textContent === "bottom",
    ) as HTMLElement;
    expect(bottom).toBeDefined();
    await act(async () => bottom.click());
    expect(panel(view.host, "bottom")).not.toBeNull();
    for (const placement of ["left", "right"] as const) {
      await act(async () => moveNativeContribution(entry, placement));
      expect(panel(view.host, placement)).not.toBeNull();
      expect(view.host.querySelectorAll('[data-testid="native-plugin-panel"]')).toHaveLength(1);
      expect(input(view.host, "move").value).toBe("移动草稿");
    }
    await act(async () => trigger(entry).click());
    expect(panel(view.host, "right")).toBeNull();
    await act(async () => trigger(entry).click());
    expect(input(view.host, "move").value).toBe("移动草稿");
    expect(view.host.querySelector('[data-testid="terminal-session"]')).toBe(terminal);
    expect(terminalMounts).toBe(1);
    expect(terminalUnmounts).toBe(0);
  } finally {
    await view.close();
  }
  expectReleased();
});

test("MainLayout same-slot replacement settles reverse opens and a late close against exact captured bindings", async () => {
  const a = contribution("right", "a"),
    b = contribution("right", "b");
  const view = await mountMainLayout([a, b]);
  const first = gate(),
    second = gate(),
    closing = gate();
  try {
    openGates.set("binding-1", first);
    openGates.set("binding-2", second);
    closeGates.set("binding-1", closing);
    await act(async () => trigger(a).click());
    await act(async () => trigger(b).click());
    expect(opened).toHaveLength(2);
    await act(async () => second.release());
    expect(prepared.map((request) => request.bindingId)).toEqual(["binding-2"]);
    await act(async () => first.release());
    expect(closed).toHaveLength(0);
    expect(input(view.host, "b").value).toBe("initial");
    await act(async () => edit(input(view.host, "b"), "B draft"));
    // Reopen A before its old native close resolves. Its new port must survive.
    await act(async () => trigger(a).click());
    expect(opened).toHaveLength(3);
    await act(async () => closing.release());
    expect(input(view.host, "a").value).toBe("initial");
    expect([...owners.values()]).toEqual(["binding-3"]);
    expect(prepared.map((request) => request.bindingId)).toEqual(["binding-2", "binding-3"]);
    const save = [...view.host.querySelectorAll("button")].find(
      (button) => button.textContent === "Save a",
    );
    expect(save).toBeDefined();
    await act(async () => save!.click());
    expect(
      prepared.some((request) => request.bindingId === "binding-3" && request.actionId === "save"),
    ).toBe(true);
    await act(async () => trigger(b).click());
    expect(input(view.host, "b").value).toBe("B draft");
  } finally {
    first.release();
    second.release();
    closing.release();
    await view.close();
  }
  expectReleased();
});

test("MainLayout reconstruction restores current workspace placement and fields through existing UI actions", async () => {
  const entry = contribution("right", "restore");
  const view = await mountMainLayout([entry]);
  try {
    await act(async () => trigger(entry).click());
    await act(async () => edit(input(view.host, "restore"), "saved draft"));
    await act(async () => moveNativeContribution(entry, "left"));
    const saved = savedUi.get("/fixture/a")!;
    expect(saved.activeSidebarView).toBe(nativeViewId(entry));
    expect(saved.isSidebarVisible).toBe(true);
    await act(async () => ui.setState(ui.getInitialState()));
    savedUi.set("/fixture/a", saved);
    await act(async () => restoreProjectUiState("/fixture/a"));
    await view.rebuild();
    expect(panel(view.host, "left")).not.toBeNull();
    expect(input(view.host, "restore").value).toBe("saved draft");
    expect(useNativeDocking.getState().placements[nativeViewId(entry)]).toBe("left");
    expect(terminalMounts).toBe(2);
    expect(terminalUnmounts).toBe(1);
  } finally {
    await view.close();
  }
  expectReleased();
});

test("MainLayout workspace switching retains only that workspace's placement and draft, and scopes persistence", async () => {
  const entry = contribution("right", "workspace");
  const view = await mountMainLayout([entry]);
  try {
    await act(async () => trigger(entry).click());
    await act(async () => edit(input(view.host, "workspace"), "A"));
    await act(async () => moveNativeContribution(entry, "left"));
    const savedA = savedUi.get("/fixture/a");
    await act(async () => activate("b"));
    expect(view.host.querySelector('[data-testid="native-plugin-panel"]')).toBeNull();
    await act(async () => trigger(entry).click());
    expect(panel(view.host, "right")).not.toBeNull();
    expect(input(view.host, "workspace").value).toBe("initial");
    await act(async () => edit(input(view.host, "workspace"), "B"));
    expect(savedUi.get("/fixture/a")).toBe(savedA);
    await act(async () => activate("a"));
    expect(panel(view.host, "left")).not.toBeNull();
    expect(input(view.host, "workspace").value).toBe("A");
    expect(opened.map((binding) => binding.path)).toEqual([
      "/fixture/a",
      "/fixture/a",
      "/fixture/b",
      "/fixture/a",
    ]);
  } finally {
    await view.close();
  }
  expectReleased();
});

test("MainLayout package withdrawal closes the current slot and replacement keeps placement without old bytes' draft", async () => {
  const entry = contribution("left", "package");
  const view = await mountMainLayout([entry]);
  try {
    await act(async () => trigger(entry).click());
    await act(async () => edit(input(view.host, "package"), "old bytes"));
    await act(async () => moveNativeContribution(entry, "bottom"));
    await act(async () => {
      setEntries([]);
      removeDeclarativeUI(entry.pluginId);
    });
    expect(view.host.querySelector('[data-testid="native-plugin-panel"]')).toBeNull();
    expect(document.getElementById(nativeTriggerId(nativeViewId(entry)))).toBeNull();
    expect(ui.getState().isBottomPaneVisible).toBe(false);
    const replacement = { ...entry, packageIdentity: "replacement-bytes" };
    await act(async () => {
      setEntries([replacement]);
      await refreshDeclarativeUI();
    });
    expect(catalog.getState().nativeWindows).toEqual([replacement]);
    await act(async () => trigger(replacement).click());
    expect(panel(view.host, "bottom")).not.toBeNull();
    expect(input(view.host, "package").value).toBe("initial");
  } finally {
    await view.close();
  }
  expectReleased();
});

test("MainLayout rebuilding under another host window isolates field drafts and releases old ports", async () => {
  const entry = contribution("right", "window");
  const view = await mountMainLayout([entry]);
  try {
    await act(async () => trigger(entry).click());
    await act(async () => edit(input(view.host, "window"), "main draft"));
    setHostLabel("secondary");
    await view.rebuild();
    expect(input(view.host, "window").value).toBe("initial");
    await act(async () => edit(input(view.host, "window"), "secondary draft"));
    setHostLabel("main");
    await view.rebuild();
    expect(input(view.host, "window").value).toBe("main draft");
    expect(opened.map((binding) => binding.host)).toEqual(["main", "secondary", "main"]);
  } finally {
    await view.close();
  }
  expectReleased();
});

test("MainLayout reconstruction retains tree selection and expansion through hide and same-slot replacement", async () => {
  const tree = contribution("bottom", "tree"),
    other = contribution("bottom", "other");
  tree.native = {
    ...tree.native,
    kind: "tree",
    controls: undefined,
    buttons: undefined,
    nodes: [
      {
        id: "root",
        label: "Root",
        children: [{ id: "child", label: "Child" }],
      },
    ],
  };
  const view = await mountMainLayout([tree, other]);
  try {
    await act(async () => trigger(tree).click());
    const region = view.host.querySelector('[role="tree"]') as HTMLElement;
    for (const key of ["Home", "ArrowRight", "ArrowDown"])
      await act(async () => {
        region.focus();
        region.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true }));
      });
    expect(
      view.host.querySelector('[role="treeitem"][aria-selected="true"]')?.textContent,
    ).toContain("Child");
    await act(async () => trigger(other).click());
    expect(view.host.querySelector('[role="tree"]')).toBeNull();
    await act(async () => trigger(tree).click());
    await act(async () => ui.getState().setIsBottomPaneVisible(false));
    expect(view.host.querySelector('[role="tree"]')).toBeNull();
    await view.rebuild();
    expect(view.host.querySelector('[role="tree"]')).toBeNull();
    await act(async () => trigger(tree).click());
    expect(
      view.host.querySelector('[role="treeitem"][aria-expanded="true"]')?.textContent,
    ).toContain("Root");
    expect(
      view.host.querySelector('[role="treeitem"][aria-selected="true"]')?.textContent,
    ).toContain("Child");
    expect(opened).toHaveLength(4);
  } finally {
    await view.close();
  }
  expectReleased();
});

test("MainLayout same-view package replacement rejects an old pending open and keeps the new owner actionable", async () => {
  const entry = contribution("right", "replacement");
  const view = await mountMainLayout([entry]);
  const opening = gate();
  try {
    openGates.set("binding-1", opening);
    await act(async () => trigger(entry).click());
    expect(opened).toHaveLength(1);
    const replacement = { ...entry, packageIdentity: "new-bytes" };
    await act(async () => {
      setEntries([replacement]);
      await refreshDeclarativeUI();
    });
    expect(opened).toHaveLength(2);
    expect(opened[1].entry.packageIdentity).toBe("new-bytes");
    await act(async () => edit(input(view.host, "replacement"), "new draft"));
    await act(async () => opening.release());
    expect(closed).toEqual(["binding-1"]);
    expect([...owners.values()]).toEqual(["binding-2"]);
    expect(input(view.host, "replacement").value).toBe("new draft");
    expect(prepared.map((request) => request.bindingId)).toEqual(["binding-2"]);
    expect(trigger(replacement).getAttribute("aria-pressed")).toBe("true");
  } finally {
    opening.release();
    await view.close();
  }
  expectReleased();
});
