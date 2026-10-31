import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { NativeContribution } from "./native-ui.types";
import {
  catalog,
  closed,
  mountWorkbench,
  opened,
  prepared,
  restoreDom,
  setHostLabel,
  setOpenGate,
  ui,
} from "./native-docking.test-support";
const {
  closeNativeContribution,
  moveNativeContribution,
  nativeTriggerId,
  nativeViewId,
  useNativeDocking,
} = await import("./native-docking");
const { deferred } = await import("./native-functions.test-support");

afterAll(restoreDom);
function contribution(placement: string, suffix = "one"): NativeContribution {
  return {
    pluginId: `fixture.${suffix}`,
    packageIdentity: `bytes-${suffix}`,
    windowId: `fixture.${suffix}.window`,
    title: `Panel ${suffix}`,
    placement,
    order: 0,
    native: {
      schemaVersion: 1,
      id: `fixture.${suffix}.panel`,
      kind: "form",
      nodes: [],
      controls: [{ id: "name", kind: "input", label: "Name", value: "initial" }],
      source: {
        buildSystemID: `fixture.${suffix}.build`,
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
      buttons: [{ id: "save-button", label: "Save", action: "save" }],
      toolbar: [],
      contextMenu: [],
    },
  };
}
function trigger(host: HTMLElement, entry: NativeContribution) {
  const button = host.ownerDocument.getElementById(
    nativeTriggerId(nativeViewId(entry)),
  ) as HTMLButtonElement;
  expect(button).not.toBeNull();
  return button;
}
function panel(host: HTMLElement) {
  return host.querySelector('[data-testid="native-plugin-panel"]')!;
}
function nameInput(host: HTMLElement) {
  return host.querySelector('input[aria-label="Name"]') as HTMLInputElement;
}
function edit(input: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}

for (const placement of ["left", "bottom", "right"] as const) {
  test(`catalog ${placement} contribution mounts in the real workbench slot; close restores rail focus and reopen restores fields`, async () => {
    const entry = contribution(placement);
    const view = await mountWorkbench([entry]);
    try {
      await act(async () => trigger(view.host, entry).click());
      expect(
        panel(view.host)
          .closest("[data-native-tool-window-slot]")
          ?.getAttribute("data-native-tool-window-slot"),
      ).toBe(placement);
      // These are the real TerminalDockLayout CSS grid parents, not a mocked renderer.
      const area = placement === "left" ? "sidebar" : placement === "right" ? "tools" : "panel";
      expect(panel(view.host).closest(`[style*="grid-area: ${area}"]`)).not.toBeNull();
      expect(
        view.host.querySelector("[data-terminal-dock]")?.getAttribute("data-terminal-dock"),
      ).toBe(placement === "bottom" ? "bottom" : "right");
      expect(opened).toHaveLength(1);
      expect(prepared[0].bindingId).toBe(opened[0].bindingId);
      expect(trigger(view.host, entry).getAttribute("aria-pressed")).toBe("true");
      await act(async () => edit(nameInput(view.host), "草稿"));
      const close = panel(view.host).querySelector(
        'button[aria-label="Close native plugin panel"]',
      ) as HTMLButtonElement;
      expect(close).not.toBeNull();
      await act(async () => {
        close.focus();
        close.click();
      });
      expect(panel(view.host)).toBeNull();
      expect(closed).toEqual([opened[0].bindingId]);
      expect(document.activeElement).toBe(trigger(view.host, entry));
      expect(trigger(view.host, entry).getAttribute("aria-pressed")).toBe("false");
      await act(async () => trigger(view.host, entry).click());
      expect(nameInput(view.host).value).toBe("草稿");
      expect(opened).toHaveLength(2);
    } finally {
      await view.close();
    }
    expect(new Set(closed).size).toBe(opened.length);
  });
}

test("the production rail context menu moves one native owner across all three slots without closing neighboring tools", async () => {
  const entry = contribution("right");
  const view = await mountWorkbench([entry]);
  try {
    await act(async () => {
      ui.getState().setIsSidebarVisible(true);
      trigger(view.host, entry).click();
    });
    await act(async () => edit(nameInput(view.host), "moved draft"));
    await act(async () =>
      trigger(view.host, entry).dispatchEvent(
        new window.MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          button: 2,
        }),
      ),
    );
    const item = Array.from(document.querySelectorAll('[role="menuitem"]')).find(
      (item) => item.textContent === "bottom",
    ) as HTMLElement;
    expect(item).not.toBeUndefined();
    await act(async () => item.click());
    expect(
      panel(view.host)
        .closest("[data-native-tool-window-slot]")
        ?.getAttribute("data-native-tool-window-slot"),
    ).toBe("bottom");
    expect(nameInput(view.host).value).toBe("moved draft");
    expect(ui.getState().isSidebarVisible).toBe(true);
    expect(ui.getState().activeSidebarView).toBe("files");
    expect(closed).toEqual([opened[0].bindingId]);
    for (const placement of ["left", "right"] as const) {
      await act(async () => moveNativeContribution(entry, placement));
      expect(view.host.querySelectorAll('[data-testid="native-plugin-panel"]')).toHaveLength(1);
      expect(
        panel(view.host)
          .closest("[data-native-tool-window-slot]")
          ?.getAttribute("data-native-tool-window-slot"),
      ).toBe(placement);
      expect(nameInput(view.host).value).toBe("moved draft");
    }
    expect(opened).toHaveLength(4);
    expect(closed).toHaveLength(3);
  } finally {
    await view.close();
  }
  expect(closed).toEqual(opened.map((binding) => binding.bindingId));
});

test("a reused bottom slot and late old native registration release only the captured handle", async () => {
  const a = contribution("bottom", "a"),
    b = contribution("bottom", "b");
  const gate = deferred<void>();
  const view = await mountWorkbench([a, b]);
  try {
    setOpenGate(gate.promise);
    await act(async () => trigger(view.host, a).click());
    expect(opened).toHaveLength(1);
    setOpenGate();
    await act(async () => trigger(view.host, b).click());
    expect(panel(view.host).textContent).toContain(b.title);
    expect(opened).toHaveLength(2);
    await act(async () => gate.resolve());
    expect(closed).toEqual([opened[0].bindingId]);
    expect(prepared.map((call) => call.bindingId)).toEqual([opened[1].bindingId]);
    expect(panel(view.host).textContent).toContain(b.title);
    expect(nameInput(view.host).value).toBe("initial");
    await act(async () => ui.getState().setBottomPaneActiveTab("gitLog"));
    expect(panel(view.host)).toBeNull();
    expect(closed).toEqual(opened.map((binding) => binding.bindingId));
  } finally {
    gate.resolve();
    setOpenGate();
    await view.close();
  }
});

test("workspace switch closes native ports, isolates layout and fields, and restores only the returning workspace", async () => {
  const entry = contribution("right");
  const view = await mountWorkbench([entry]);
  try {
    ui.getStore("r13-b");
    useNativeDocking.getStore("r13-b");
    workspaceRuntimeRegistry.ensureWorkspace({
      id: "r13-b",
      name: "B",
      path: "/fixture/b",
    });
    workspaceRuntimeRegistry.updateWorkspaceStatus("r13-b", "ready");
    await act(async () => trigger(view.host, entry).click());
    await act(async () => {
      edit(nameInput(view.host), "workspace A");
    });
    await act(async () => moveNativeContribution(entry, "left"));
    await act(async () =>
      trigger(view.host, entry).dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, button: 2 }),
      ),
    );
    expect(document.querySelector('[role="menu"]')).not.toBeNull();
    await act(async () =>
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "r13-b", name: "B", path: "/fixture/b" },
        "ready",
      ),
    );
    expect(panel(view.host)).toBeNull();
    expect(document.querySelector('[role="menu"]')).toBeNull();
    expect(closed).toHaveLength(2);
    await act(async () => trigger(view.host, entry).click());
    expect(
      panel(view.host)
        .closest("[data-native-tool-window-slot]")
        ?.getAttribute("data-native-tool-window-slot"),
    ).toBe("right");
    expect(nameInput(view.host).value).toBe("initial");
    // A delayed callback must not invoke A's UI actions while B owns the
    // active project used by their existing visibility persistence adapter.
    await act(async () => closeNativeContribution(nativeViewId(entry), "left", "r13-a"));
    expect(ui.getStore("r13-a").getState().isSidebarVisible).toBe(true);
    expect(ui.getState().isRightSidebarVisible).toBe(true);
    await act(async () => edit(nameInput(view.host), "workspace B"));
    await act(async () =>
      workspaceRuntimeRegistry.activateWorkspace({ id: "r13-a", name: "A" }, "ready"),
    );
    expect(nameInput(view.host).value).toBe("workspace A");
    expect(
      panel(view.host)
        .closest("[data-native-tool-window-slot]")
        ?.getAttribute("data-native-tool-window-slot"),
    ).toBe("left");
    expect(opened.map((owner) => owner.path)).toEqual([
      "/fixture/a",
      "/fixture/a",
      "/fixture/b",
      "/fixture/a",
    ]);
  } finally {
    await view.close();
  }
  expect(new Set(closed).size).toBe(opened.length);
});

test("catalog removal unmounts native content and package replacement retains placement without inheriting old drafts", async () => {
  const entry = contribution("left");
  const view = await mountWorkbench([entry]);
  try {
    await act(async () => trigger(view.host, entry).click());
    await act(async () => edit(nameInput(view.host), "old bytes"));
    await act(async () => moveNativeContribution(entry, "bottom"));
    await act(async () => catalog.setState({ nativeWindows: [] }));
    expect(panel(view.host)).toBeNull();
    expect(closed).toHaveLength(2);
    expect(ui.getState().isBottomPaneVisible).toBe(false);
    const replacement = { ...entry, packageIdentity: "new bytes" };
    await act(async () => catalog.setState({ nativeWindows: [replacement] }));
    expect(panel(view.host)).toBeNull();
    await act(async () => trigger(view.host, replacement).click());
    expect(nameInput(view.host).value).toBe("initial");
    expect(
      panel(view.host)
        .closest("[data-native-tool-window-slot]")
        ?.getAttribute("data-native-tool-window-slot"),
    ).toBe("bottom");
    expect(useNativeDocking.getState().placements[nativeViewId(entry)]).toBe("bottom");
    expect(opened).toHaveLength(3);
  } finally {
    await view.close();
  }
  expect(new Set(closed).size).toBe(opened.length);
});

test("bottom long trees retain the real virtualizer and keyboard expansion through hide and reopen", async () => {
  const entry = contribution("bottom");
  entry.native = {
    ...entry.native,
    kind: "tree",
    controls: undefined,
    buttons: undefined,
    nodes: [
      {
        id: "root",
        label: "Root",
        children: Array.from({ length: 1500 }, (_, index) => ({
          id: `n${index}`,
          label: `Node ${index}`,
        })),
      },
    ],
  };
  const view = await mountWorkbench([entry]);
  try {
    await act(async () => trigger(view.host, entry).click());
    const tree = view.host.querySelector('[role="tree"]') as HTMLElement;
    await act(async () => {
      tree.focus();
      tree.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Home", bubbles: true }));
    });
    await act(async () =>
      tree.dispatchEvent(
        new window.KeyboardEvent("keydown", {
          key: "ArrowRight",
          bubbles: true,
        }),
      ),
    );
    expect(view.host.querySelector('[role="treeitem"]')?.getAttribute("aria-expanded")).toBe(
      "true",
    );
    expect(view.host.querySelectorAll('[role="treeitem"]').length).toBeLessThan(50);
    await act(async () => trigger(view.host, entry).click());
    expect(panel(view.host)).toBeNull();
    await act(async () => trigger(view.host, entry).click());
    expect(view.host.querySelector('[role="treeitem"]')?.getAttribute("aria-expanded")).toBe(
      "true",
    );
    expect(view.host.querySelector('[role="treeitem"]')?.getAttribute("aria-selected")).toBe(
      "true",
    );
    expect(view.host.querySelectorAll('[role="treeitem"]').length).toBeLessThan(50);
  } finally {
    await view.close();
  }
});

test("host window identities retain separate native drafts and release their exact ports", async () => {
  const entry = contribution("right");
  const view = await mountWorkbench([entry]);
  try {
    await act(async () => trigger(view.host, entry).click());
    await act(async () => edit(nameInput(view.host), "window one"));
    setHostLabel("secondary");
    await view.render();
    expect(nameInput(view.host).value).toBe("initial");
    expect(closed).toEqual([opened[0].bindingId]);
    await act(async () => edit(nameInput(view.host), "window two"));
    setHostLabel("main");
    await view.render();
    expect(nameInput(view.host).value).toBe("window one");
    expect(opened.map((binding) => binding.host)).toEqual(["main", "secondary", "main"]);
  } finally {
    await view.close();
  }
  expect(closed).toEqual(opened.map((binding) => binding.bindingId));
});

test("narrow workbench updates preserve the field DOM, focus and one native binding", async () => {
  const entry = contribution("left");
  entry.native.layout = { columns: 2 };
  entry.native.controls![0].onCommit = "save";
  const view = await mountWorkbench([entry]);
  const oldWidth = window.innerWidth;
  try {
    await act(async () => trigger(view.host, entry).click());
    const input = nameInput(view.host);
    await act(async () => {
      input.focus();
      edit(input, "中文");
    });
    await act(async () => {
      for (const width of [1000, 700, 500, 320]) {
        window.innerWidth = width;
        window.dispatchEvent(new window.Event("resize"));
      }
    });
    expect(nameInput(view.host)).toBe(input);
    expect(document.activeElement).toBe(input);
    expect(opened).toHaveLength(1);
    expect(closed).toHaveLength(0);
    expect(view.host.querySelector(".plugin-native-form")).not.toBeNull();
    await act(async () => {
      input.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
      input.dispatchEvent(
        new window.KeyboardEvent("keydown", {
          key: "Enter",
          bubbles: true,
          isComposing: true,
        }),
      );
    });
    expect(prepared).toHaveLength(1);
    await act(async () => {
      input.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
      input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    // Successful actions refresh through the existing source; only one call is
    // the form commit, followed by a distinct data load on the same binding.
    expect(prepared).toHaveLength(3);
    expect(prepared.filter((call) => call.actionId === "save")).toHaveLength(1);
    expect(prepared[1].actionId).toBe("save");
    expect(prepared[1].values).toEqual({ name: "中文" });
  } finally {
    window.innerWidth = oldWidth;
    await view.close();
  }
});
