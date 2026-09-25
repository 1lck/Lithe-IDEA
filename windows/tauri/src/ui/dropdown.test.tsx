import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { Dropdown } from "./dropdown";

let restoreDom: () => void;
let restoreLayout: () => void;
let root: Root | undefined;
let container: HTMLDivElement;
let scale: number;
let menuHeight: number;
const observers = new Map<Element, ResizeObserverCallback>();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let previousResizeObserver: PropertyDescriptor | undefined;

// Happy DOM has no layout. Keep layout size and animated visual size separate,
// then finish the animation explicitly before focus causes a parent rerender.
function installMenuLayout() {
  const prototype = window.HTMLElement.prototype;
  const descriptors = ["offsetWidth", "offsetHeight", "getBoundingClientRect"].map(
    (key) => [key, Object.getOwnPropertyDescriptor(prototype, key)] as const,
  );
  Object.defineProperties(window.HTMLElement.prototype, {
    offsetWidth: {
      configurable: true,
      get(this: HTMLElement) {
        return Number.parseFloat(this.style.width) || 240;
      },
    },
    offsetHeight: {
      configurable: true,
      get(this: HTMLElement) {
        return Math.min(menuHeight, Number.parseFloat(this.style.maxHeight) || menuHeight);
      },
    },
  });
  window.HTMLElement.prototype.getBoundingClientRect = function () {
    return new window.DOMRect(0, 0, this.offsetWidth * scale, this.offsetHeight * scale);
  };
  return () => {
    for (const [key, descriptor] of descriptors) {
      if (descriptor) Object.defineProperty(prototype, key, descriptor);
      else Reflect.deleteProperty(prototype, key);
    }
  };
}

class ControlledResizeObserver {
  constructor(private callback: ResizeObserverCallback) {}
  observe(target: Element) {
    observers.set(target, this.callback);
  }
  unobserve(target: Element) {
    observers.delete(target);
  }
  disconnect() {
    for (const [target, callback] of observers) {
      if (callback === this.callback) observers.delete(target);
    }
  }
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousResizeObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    value: ControlledResizeObserver,
  });
  Object.defineProperties(window, {
    innerWidth: { configurable: true, value: 1024 },
    innerHeight: { configurable: true, value: 1032 },
  });
  scale = 0.98;
  menuHeight = 398;
  restoreLayout = installMenuLayout();
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root?.unmount());
    expect(observers.size).toBe(0);
  } finally {
    root = undefined;
    container.remove();
    observers.clear();
    if (previousResizeObserver)
      Object.defineProperty(globalThis, "ResizeObserver", previousResizeObserver);
    else Reflect.deleteProperty(globalThis, "ResizeObserver");
    if (previousActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreLayout();
    restoreDom();
  }
});

async function render(element: ReactNode) {
  await act(async () => root!.render(<LocaleProvider language="en-US">{element}</LocaleProvider>));
}

function menu() {
  return document.querySelector<HTMLDivElement>('[role="menu"]')!.parentElement!;
}

test("edge context menu stays under the pointer when focus follows its entrance animation", async () => {
  const select = mock(() => {});
  function Parent() {
    const [, rerender] = useState(0);
    const [open, setOpen] = useState(true);
    return (
      <div onFocus={() => rerender((value) => value + 1)}>
        <Dropdown
          isOpen={open}
          animated={false}
          point={{ x: 780, y: 632 }}
          onClose={() => setOpen(false)}
          items={[{ id: "properties", label: "Properties", onClick: select }]}
        />
      </div>
    );
  }
  await render(<Parent />);
  const initial = { left: menu().style.left, top: menu().style.top, width: menu().style.width };
  expect(initial).toEqual({ left: "540px", top: "234px", width: "240px" });

  scale = 1;
  const button = document.querySelector<HTMLButtonElement>('[role="menuitem"]')!;
  await act(async () => button.focus());
  expect({ left: menu().style.left, top: menu().style.top, width: menu().style.width }).toEqual(
    initial,
  );
  await act(async () => button.click());
  expect(select).toHaveBeenCalledTimes(1);
  expect(document.querySelector('[role="menu"]')).toBeNull();
});

test("a point menu keeps its pointer origin when there is enough room", async () => {
  await render(
    <Dropdown isOpen animated={false} point={{ x: 100, y: 120 }} onClose={() => {}} items={[]} />,
  );
  expect(menu().style.left).toBe("100px");
  expect(menu().style.top).toBe("120px");
});

test("an anchored menu uses its full height and follows a moved anchor", async () => {
  const anchor = document.createElement("button");
  container.append(anchor);
  let anchorY = 700;
  anchor.getBoundingClientRect = () => new window.DOMRect(850, anchorY, 100, 24);
  await render(
    <Dropdown
      isOpen
      animated={false}
      anchorRef={{ current: anchor }}
      anchorAlign="end"
      onClose={() => {}}
      items={[]}
    />,
  );
  expect(menu().style.left).toBe("710px");
  expect(menu().style.top).toBe("296px");

  scale = 1;
  anchorY = 650;
  await act(async () => window.dispatchEvent(new Event("resize")));
  expect(menu().style.left).toBe("710px");
  expect(menu().style.top).toBe("246px");
});

test("a menu still repositions when its content becomes taller", async () => {
  scale = 1;
  menuHeight = 200;
  await render(
    <Dropdown isOpen animated={false} point={{ x: 100, y: 632 }} onClose={() => {}} items={[]} />,
  );
  expect(menu().style.top).toBe("632px");
  const element = menu();
  menuHeight = 500;
  await act(async () => {
    observers.get(element)!(
      [
        {
          target: element,
          contentRect: new window.DOMRect(0, 0, 240, menuHeight),
          borderBoxSize: [],
          contentBoxSize: [],
          devicePixelContentBoxSize: [],
        },
      ],
      {} as ResizeObserver,
    );
  });
  expect(menu().style.top).toBe("132px");
});

test("a menu item with children opens a nested submenu", async () => {
  const select = mock(() => {});
  await render(
    <Dropdown
      isOpen
      animated={false}
      point={{ x: 40, y: 60 }}
      onClose={() => {}}
      items={[
        {
          id: "git",
          label: "Git",
          onClick: () => {},
          children: [{ id: "git-fetch", label: "Fetch", onClick: select }],
        },
      ]}
    />,
  );

  expect(document.querySelectorAll('[role="menu"]').length).toBe(1);

  const trigger = document.querySelector<HTMLButtonElement>('[role="menuitem"]')!;
  expect(trigger.getAttribute("aria-haspopup")).toBe("menu");
  await act(async () => trigger.focus());

  const menus = document.querySelectorAll('[role="menu"]');
  expect(menus.length).toBe(2);

  const child = [...document.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')].find(
    (button) => button.textContent?.includes("Fetch"),
  )!;
  await act(async () => child.click());
  expect(select).toHaveBeenCalledTimes(1);
});
