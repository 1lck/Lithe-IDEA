import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { InfoTip } = await import("./info-tip");
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let host: HTMLDivElement;
let root: Root;
let timers: Map<ReturnType<typeof setTimeout>, () => void>;
let restoreTimers: () => void;

beforeEach(async () => {
  previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  timers = new Map();
  const setTimer = globalThis.setTimeout;
  const clearTimer = globalThis.clearTimeout;
  const set = spyOn(globalThis, "setTimeout").mockImplementation(((
    callback: (...args: unknown[]) => void,
    delay?: number,
    ...args: unknown[]
  ) => {
    if (delay !== 500) return setTimer(callback, delay, ...args);
    const timer = {} as ReturnType<typeof setTimeout>;
    timers.set(timer, () => callback(...args));
    return timer;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation((timer) => {
    if (timer && timers.delete(timer as ReturnType<typeof setTimeout>)) return;
    clearTimer(timer as number | undefined);
  });
  restoreTimers = () => {
    set.mockRestore();
    clear.mockRestore();
  };
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <InfoTip label="Field explanation" content={"Literal <b>help</b>\n第二行"} />
        <button type="button">Outside</button>
      </LocaleProvider>,
    ),
  );
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
    expect(timers.size).toBe(0);
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  } finally {
    host.remove();
    timers.clear();
    restoreTimers();
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});

const trigger = () =>
  host.querySelector<HTMLButtonElement>('button[aria-label="Field explanation"]')!;
const outside = () =>
  [...host.querySelectorAll("button")].find((button) => button.textContent === "Outside")!;
const expanded = () => trigger().getAttribute("aria-expanded");
async function advanceHoverDelay() {
  expect(timers.size).toBeGreaterThan(0);
  // Run only callbacks already due; newly scheduled patient-click timers are a
  // separate turn, so the test controls both sides of Base UI's threshold.
  const due = [...timers];
  await act(async () => {
    for (const [timer, callback] of due) {
      timers.delete(timer);
      callback();
    }
  });
}
async function hover() {
  await act(async () => {
    trigger().dispatchEvent(new window.MouseEvent("mouseenter", { clientX: 0, clientY: 0 }));
    trigger().dispatchEvent(
      new window.MouseEvent("mousemove", { bubbles: true, clientX: 0, clientY: 0 }),
    );
  });
}
async function leave() {
  await act(async () => {
    trigger().dispatchEvent(
      new window.MouseEvent("mouseleave", { clientX: 800, clientY: 800, relatedTarget: outside() }),
    );
    outside().dispatchEvent(
      new window.MouseEvent("mousemove", { bubbles: true, clientX: 800, clientY: 800 }),
    );
  });
}

test("click pins a literal accessible explanation and toggles it through a non-submit button", async () => {
  const button = trigger();
  expect(button.tagName).toBe("BUTTON");
  expect(button.type).toBe("button");
  expect(document.getElementById(button.getAttribute("aria-describedby")!)?.textContent).toBe(
    "Literal <b>help</b>\n第二行",
  );
  await act(async () => {
    button.focus();
    button.click();
  });
  expect(expanded()).toBe("true");
  const popup = document.querySelector('[role="dialog"]')!;
  expect(popup.getAttribute("aria-label")).toBe("Field explanation");
  expect(popup.textContent).toBe("Literal <b>help</b>\n第二行");
  expect(popup.querySelector("b")).toBeNull();
  expect(document.activeElement).toBe(button);
  await leave();
  expect(expanded()).toBe("true");
  await act(async () => button.click());
  expect(expanded()).toBe("false");
}, 3000);

for (const key of ["Enter", " "]) {
  test(`native button activation with ${key === " " ? "Space" : key} pins and toggles the explanation`, async () => {
    const button = trigger();
    const activate = async () =>
      act(async () => {
        button.focus();
        const down = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
        button.dispatchEvent(down);
        button.dispatchEvent(new KeyboardEvent("keyup", { key, bubbles: true }));
        // Happy DOM does not implement native button default keyboard activation.
        // Deliver that browser click explicitly; verify the real owner receives
        // exactly one activation and does not suppress the native key default.
        expect(down.defaultPrevented).toBe(false);
        button.click();
      });
    await activate();
    expect(expanded()).toBe("true");
    await activate();
    expect(expanded()).toBe("false");
  }, 3000);
}

test("Escape dismisses with trigger focus and outside press dismisses without stealing focus", async () => {
  await act(async () => {
    trigger().focus();
    trigger().click();
  });
  await act(async () =>
    trigger().dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
  );
  expect(expanded()).toBe("false");
  expect(document.activeElement).toBe(trigger());
  await act(async () => trigger().click());
  await act(async () => {
    outside().dispatchEvent(
      new window.PointerEvent("pointerdown", { bubbles: true, pointerType: "mouse" }),
    );
    outside().dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
    outside().focus();
    outside().click();
  });
  expect(expanded()).toBe("false");
  expect(document.activeElement).toBe(outside());
}, 3000);

test("hover waits for its owned delay, cancels on leave and pins after the patient-click threshold", async () => {
  await hover();
  expect(expanded()).toBe("false");
  await leave();
  // Base UI also schedules its patient-click bookkeeping on a hover close.
  // Advance that owned timer and prove the cancelled hover cannot open later.
  await advanceHoverDelay();
  expect(expanded()).toBe("false");
  expect(timers.size).toBe(0);
  await hover();
  await advanceHoverDelay();
  expect(expanded()).toBe("true");
  await advanceHoverDelay();
  await act(async () => trigger().click());
  await leave();
  expect(expanded()).toBe("true");
  await act(async () => trigger().click());
  expect(expanded()).toBe("false");
}, 3000);

test("hover dismissal and unmount release pending timers and popup resources", async () => {
  await act(async () => outside().focus());
  await hover();
  await advanceHoverDelay();
  expect(expanded()).toBe("true");
  expect(document.activeElement).toBe(outside());
  await leave();
  expect(expanded()).toBe("false");
  expect(document.activeElement).toBe(outside());
  await act(async () => root.render(null));
  expect(timers.size).toBe(0);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
}, 3000);

test("unmount before the hover deadline cancels its delayed open", async () => {
  await hover();
  expect(timers.size).toBeGreaterThan(0);
  await act(async () => root.render(null));
  expect(timers.size).toBe(0);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
}, 3000);
