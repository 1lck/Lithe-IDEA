import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { DeclarativeWebToolWindow } from "../declarative-plugin-launch";
import {
  activate,
  mountMainLayout,
  refreshDeclarativeUI,
  restoreDom,
  setWebEntries,
  webOpened,
  webClosed,
  webLayouts,
  gate,
  openGates,
  ui,
} from "../native-ui/native-main-layout.test-support";
const { moveNativeContribution, nativeTriggerId, nativeViewId } =
  await import("../native-ui/native-docking");

afterAll(restoreDom);
let bounds: DOMRect;
let restoreBounds = () => {};
beforeEach(() => {
  bounds = new DOMRect(0, 0, 200, 100);
  const original = HTMLElement.prototype.getBoundingClientRect;
  const spy = spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(
    function (this: HTMLElement) {
      return this.hasAttribute("data-plugin-web-body") ? bounds : original.call(this);
    },
  );
  restoreBounds = () => spy.mockRestore();
});
afterEach(() => restoreBounds());

async function resize(view: Awaited<ReturnType<typeof mountMainLayout>>) {
  await act(async () => {
    window.dispatchEvent(new window.Event("resize"));
  });
  await view.render(); // Drain the workbench's controlled animation frame.
}
function contribution(placement: string): DeclarativeWebToolWindow {
  return {
    pluginId: "fixture.web",
    packageIdentity: "bytes-one",
    windowId: "fixture.web.window",
    title: "Web fixture",
    entry: "ui/index.html",
    placement,
    order: 0,
  };
}
function trigger(entry: DeclarativeWebToolWindow) {
  const button = document.getElementById(nativeTriggerId(nativeViewId(entry))) as HTMLButtonElement;
  expect(button).not.toBeNull();
  return button;
}
const panel = (host: HTMLElement) => host.querySelector("[data-plugin-web-panel]");
const placement = (host: HTMLElement) =>
  panel(host)
    ?.closest("[data-native-tool-window-slot]")
    ?.getAttribute("data-native-tool-window-slot");

for (const side of ["left", "bottom", "right"] as const) {
  test(`MainLayout web contribution uses ${side} slot, exact close receipt and rail focus`, async () => {
    const entry = contribution(side);
    const view = await mountMainLayout([], [entry]);
    try {
      await act(async () => trigger(entry).click());
      expect(placement(view.host)).toBe(side);
      expect(webOpened).toHaveLength(1);
      expect(webOpened[0].path).toBe("/fixture/a");
      const close = panel(view.host)!.querySelector(
        'button[aria-label="Close plugin panel"]',
      ) as HTMLButtonElement;
      expect(close).not.toBeNull();
      await act(async () => close.click());
      expect(panel(view.host)).toBeNull();
      expect(webClosed).toEqual([webOpened[0].mountId]);
      expect(document.activeElement).toBe(trigger(entry));
      await act(async () => trigger(entry).click());
      expect(placement(view.host)).toBe(side);
      expect(webOpened).toHaveLength(2);
    } finally {
      await view.close();
    }
    expect(webClosed).toEqual(webOpened.map((owner) => owner.mountId));
  });
}

test("MainLayout moves and replaces a web package without inheriting its old native receipt", async () => {
  const entry = contribution("right");
  const view = await mountMainLayout([], [entry]);
  try {
    await act(async () => trigger(entry).click());
    for (const side of ["bottom", "left"] as const) {
      await act(async () => moveNativeContribution(entry, side));
      expect(placement(view.host)).toBe(side);
      expect(view.host.querySelectorAll("[data-plugin-web-panel]")).toHaveLength(1);
    }
    const replacement = { ...entry, packageIdentity: "bytes-two" };
    setWebEntries([replacement]);
    await act(async () => refreshDeclarativeUI());
    expect(placement(view.host)).toBe("left");
    expect(webOpened[webOpened.length - 1]!.packageIdentity).toBe("bytes-two");
    expect(webClosed).toEqual(webOpened.slice(0, -1).map((owner) => owner.mountId));
    setWebEntries([]);
    await act(async () => refreshDeclarativeUI());
    expect(panel(view.host)).toBeNull();
    expect(ui.getState().isSidebarVisible).toBe(false);
  } finally {
    await view.close();
  }
  expect(webClosed).toEqual(webOpened.map((owner) => owner.mountId));
});

test("MainLayout workspace switch closes the old web receipt and restores only that workspace's placement", async () => {
  const entry = contribution("right");
  const view = await mountMainLayout([], [entry]);
  try {
    await act(async () => trigger(entry).click());
    await act(async () => moveNativeContribution(entry, "left"));
    await act(async () => activate("b"));
    expect(panel(view.host)).toBeNull();
    await act(async () => trigger(entry).click());
    expect(placement(view.host)).toBe("right");
    expect(webOpened[webOpened.length - 1]!.path).toBe("/fixture/b");
    await act(async () => activate("a"));
    expect(placement(view.host)).toBe("left");
    expect(webOpened[webOpened.length - 1]!.path).toBe("/fixture/a");
  } finally {
    await view.close();
  }
  expect(webClosed).toEqual(webOpened.map((owner) => owner.mountId));
});

test("an initially zero-sized web slot unmounts without creating or waiting for a native owner", async () => {
  bounds = new DOMRect();
  const entry = contribution("right");
  const view = await mountMainLayout([], [entry]);
  try {
    await act(async () => trigger(entry).click());
    expect(panel(view.host)).not.toBeNull();
    expect(webOpened).toHaveLength(0);
  } finally {
    await view.close();
  }
  expect(webClosed).toHaveLength(0);
});

test("a zero-sized web slot creates exactly one native owner when its viewport becomes usable", async () => {
  bounds = new DOMRect();
  const entry = contribution("right");
  const view = await mountMainLayout([], [entry]);
  try {
    await act(async () => trigger(entry).click());
    expect(webOpened).toHaveLength(0);
    bounds = new DOMRect(0, 0, 200, 100);
    await resize(view);
    expect(webOpened).toHaveLength(1);
    await resize(view);
    expect(webOpened).toHaveLength(1);
  } finally {
    await view.close();
  }
  expect(webClosed).toEqual(webOpened.map((owner) => owner.mountId));
});

test("zero size during pending mount keeps the captured valid bounds and settles hidden", async () => {
  const entry = contribution("right");
  const view = await mountMainLayout([], [entry]);
  const pending = gate();
  openGates.set("web-1", pending);
  try {
    await act(async () => trigger(entry).click());
    expect(webOpened).toHaveLength(1);
    bounds = new DOMRect();
    await resize(view);
    expect(webOpened[0].bounds).toEqual({ x: 0, y: 0, width: 200, height: 100 });
    await act(async () => pending.release());
    expect(webLayouts).toEqual([{ mountId: "web-1", visible: false }]);
  } finally {
    pending.release();
    await view.close();
  }
  expect(webClosed).toEqual(["web-1"]);
});
