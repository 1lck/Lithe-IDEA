import { afterAll, expect, test } from "bun:test";
import { act, createRef, useState, type ComponentProps } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { SearchField } = await import("./search");

async function mount(
  props: Partial<ComponentProps<typeof SearchField>> = {},
  language: "en-US" | "zh-CN" = "en-US",
) {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const ref = createRef<HTMLInputElement>();
  const changes: string[] = [];
  let submits = 0;
  let root: Root | undefined;
  function Probe() {
    const [value, setValue] = useState("query 中文 😀");
    return (
      <LocaleProvider language={language}>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            submits++;
          }}
        >
          <label htmlFor="search-probe">Query</label>
          <SearchField
            id="search-probe"
            ref={ref}
            value={value}
            onChange={(next) => {
              changes.push(next);
              setValue(next);
            }}
            {...props}
          />
        </form>
      </LocaleProvider>
    );
  }
  const close = async () => {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  };
  try {
    await act(async () => {
      root = createRoot(host);
      root.render(<Probe />);
    });
  } catch (error) {
    await close();
    throw error;
  }
  return { host, ref, changes, close, submits: () => submits };
}

function type(input: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}

for (const activation of ["mouse", "Enter", " "] as const) {
  test(`search clear ${activation === " " ? "Space" : activation} changes once, keeps the input ref and returns editing focus`, async () => {
    const mounted = await mount();
    try {
      const input = mounted.ref.current!;
      expect(input.labels?.[0].textContent).toBe("Query");
      const button = mounted.host.querySelector<HTMLButtonElement>(
        'button[aria-label="Clear search"]',
      )!;
      expect(button.tagName).toBe("BUTTON");
      expect(button.type).toBe("button");
      button.focus();
      await act(async () => {
        if (activation !== "mouse") {
          button.dispatchEvent(new KeyboardEvent("keydown", { key: activation, bubbles: true }));
          button.dispatchEvent(new KeyboardEvent("keyup", { key: activation, bubbles: true }));
          expect(mounted.changes).toEqual([]);
        }
        // Happy DOM does not synthesize a button's keyboard default click. Supply
        // that browser action explicitly; this is not WebView2 keyboard evidence.
        button.click();
      });
      expect(mounted.changes).toEqual([""]);
      expect(mounted.submits()).toBe(0);
      expect(mounted.host.querySelector("button")).toBeNull();
      expect(mounted.ref.current).toBe(input);
      expect(input.value).toBe("");
      expect(document.activeElement).toBe(input);
      await act(async () => type(input, "next"));
      expect(mounted.changes).toEqual(["", "next"]);
      expect(mounted.host.querySelector("button")).not.toBeNull();
    } finally {
      await mounted.close();
      expect(mounted.ref.current).toBeNull();
    }
  }, 3000);
}

test("search clear uses the existing Chinese translation and stays disabled for disabled or readOnly inputs", async () => {
  for (const props of [{ disabled: true }, { readOnly: true }]) {
    const mounted = await mount(props, "zh-CN");
    try {
      const button = mounted.host.querySelector<HTMLButtonElement>(
        'button[aria-label="清除搜索"]',
      )!;
      expect(mounted.ref.current!.disabled).toBe("disabled" in props);
      expect(mounted.ref.current!.readOnly).toBe("readOnly" in props);
      expect(button.disabled).toBe(true);
      await act(async () => button.click());
      expect(mounted.changes).toEqual([]);
      expect(mounted.ref.current!.value).toBe("query 中文 😀");
    } finally {
      await mounted.close();
    }
  }
}, 3000);

test("search keeps controlled ownership, input callbacks, IME events and public size/theme classes", async () => {
  const changes: string[] = [];
  const keys: boolean[] = [];
  const compositions: string[] = [];
  const mounted = await mount({
    value: "owned",
    onChange: (value) => changes.push(value),
    size: "md",
    variant: "ghost",
    className: "caller-input",
    containerClassName: "caller-container",
    onKeyDown: (event) => keys.push(event.nativeEvent.isComposing),
    onCompositionStart: () => compositions.push("start"),
    onCompositionEnd: () => compositions.push("end"),
  });
  try {
    const input = mounted.ref.current!;
    expect(input.className).toContain("h-8");
    expect(input.className).toContain("bg-transparent");
    expect(input.className).toContain("caller-input");
    expect(input.className).toContain("pl-9");
    expect(input.className).toContain("pr-8");
    expect(input.parentElement!.className).toContain("caller-container");
    await act(async () => {
      input.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
      type(input, "候选");
      input.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true }),
      );
      input.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(changes).toEqual(["候选"]);
    expect(compositions).toEqual(["start", "end"]);
    expect(keys).toEqual([true, false]);
    await act(async () => mounted.host.querySelector<HTMLButtonElement>("button")!.click());
    expect(changes).toEqual(["候选", ""]);
    expect(input.value).toBe("owned");
    expect(mounted.host.querySelector("button")).not.toBeNull();
  } finally {
    await mounted.close();
  }
}, 3000);
