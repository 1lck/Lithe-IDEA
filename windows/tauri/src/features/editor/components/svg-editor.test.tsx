import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { create } from "zustand";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { isImageFile, isKnownTextFile } from "@/features/file-system/controllers/file-utils";

const restoreDom = installHappyDom();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
const previousDOMRect = globalThis.DOMRect;
globalThis.DOMRect = window.DOMRect;
const previousResizeObserver = globalThis.ResizeObserver;
globalThis.ResizeObserver = window.ResizeObserver;
const source = '<svg xmlns="http://www.w3.org/2000/svg"><text>original</text></svg>';
const buffer: EditorContent = {
  id: "svg-test",
  type: "editor",
  path: "fixtures/icon.svg",
  name: "icon.svg",
  content: source,
  savedContent: source,
  isDirty: false,
  isVirtual: false,
  isPinned: false,
  isPreview: false,
  isActive: true,
  tokens: [],
};
const store = create<{ buffers: EditorContent[] }>(() => ({ buffers: [buffer] }));
mock.module("../stores/buffer.store", () => ({ useBufferStore: store }));
mock.module("@/i18n/locale-provider", () => ({
  useTranslation: () => ({ t: (key: string) => key }),
}));
const { SvgEditor } = await import("./svg-editor");
let root: Root | undefined;
let container: HTMLDivElement | undefined;

async function mount(enabled = true) {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root!.render(
      <SvgEditor enabled={enabled} bufferId={buffer.id}>
        <textarea defaultValue={source} />
      </SvgEditor>,
    );
  });
}
async function selectMode(mode: string) {
  const button = [...container!.querySelectorAll("button")].find(
    (element) => element.textContent === `svg.${mode}`,
  );
  expect(button).toBeDefined();
  await act(async () => {
    button!.click();
  });
}
afterEach(async () => {
  await act(async () => {
    root?.unmount();
  });
  root = undefined;
  container?.remove();
  container = undefined;
  store.setState({ buffers: [buffer] });
});
afterAll(() => {
  actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  globalThis.ResizeObserver = previousResizeObserver;
  globalThis.DOMRect = previousDOMRect;
  restoreDom();
});

test("SVG uses editable text routing, including uppercase extensions", () => {
  for (const path of ["fixtures/icon.svg", "fixtures/icon.SVG"]) {
    expect(isImageFile(path)).toBe(false);
    expect(isKnownTextFile(path)).toBe(true);
  }
  expect(isImageFile("fixtures/icon.png")).toBe(true);
});

test("switches between split, editor, and preview without changing the buffer", async () => {
  await mount();
  expect(container!.querySelector("textarea")).not.toBeNull();
  expect(container!.querySelector("img")).not.toBeNull();
  await selectMode("editor");
  expect(container!.querySelector("textarea")).not.toBeNull();
  expect(container!.querySelector("img")).toBeNull();
  await selectMode("preview");
  expect(container!.querySelector("textarea")).toBeNull();
  expect(container!.querySelector("img")).not.toBeNull();
  expect(store.getState().buffers[0]!.content).toBe(source);
});

test("preview follows successive unsaved edits and recovers after invalid SVG", async () => {
  await mount();
  for (const text of ["first", "second"]) {
    await act(async () => {
      store.setState({
        buffers: [{ ...buffer, content: source.replace("original", text), isDirty: true }],
      });
    });
    expect(decodeURIComponent(container!.querySelector("img")!.src)).toContain(text);
  }
  await act(async () => {
    container!.querySelector("img")!.dispatchEvent(new Event("error"));
  });
  expect(container!.querySelector('[role="status"]')?.textContent).toBe("svg.invalid");
  await act(async () => {
    store.setState({ buffers: [{ ...buffer, content: source }] });
  });
  expect(container!.querySelector("img")).not.toBeNull();
  expect(container!.querySelector("svg")).toBeNull();
});

test("ordinary source files keep their original editor surface", async () => {
  await mount(false);
  expect(container!.querySelector("textarea")).not.toBeNull();
  expect(container!.querySelector("button")).toBeNull();
});
