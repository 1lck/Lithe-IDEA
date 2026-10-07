import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createPortal } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { isTreeDomEvent } from "./tree-dom-event";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let portal: HTMLDivElement;
let previousAct: boolean | undefined;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  portal = document.createElement("div");
  document.body.append(container, portal);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  portal.remove();
  environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  restoreDom();
});

test("portal submit click retains its native default; real tree clicks are handled", async () => {
  let submits = 0;
  let treeClicks = 0;
  await act(async () =>
    root.render(
      <div
        onClick={(event) => {
          if (!isTreeDomEvent(event)) return;
          event.preventDefault();
          treeClicks++;
        }}
      >
        <button data-tree-row="true">row</button>
        {createPortal(
          <form
            id="package-form"
            onSubmit={(event) => {
              event.preventDefault();
              submits++;
            }}
          >
            <input defaultValue="com.example" />
            <button type="submit">Create</button>
          </form>,
          portal,
        )}
      </div>,
    ),
  );
  await act(async () => portal.querySelector<HTMLButtonElement>("button")!.click());
  expect(submits).toBe(1);
  expect(treeClicks).toBe(0);
  await act(async () => container.querySelector<HTMLButtonElement>("button")!.click());
  expect(treeClicks).toBe(1);
});

test("a portal checkbox toggles and keyboard defaults are not canceled by the tree", async () => {
  let bubbledKeys = 0;
  await act(async () =>
    root.render(
      <div
        onClick={(event) => {
          if (isTreeDomEvent(event)) event.preventDefault();
        }}
        onKeyDown={(event) => {
          if (!isTreeDomEvent(event)) return;
          bubbledKeys++;
          event.preventDefault();
        }}
      >
        {createPortal(<input type="checkbox" />, portal)}
      </div>,
    ),
  );
  const checkbox = portal.querySelector<HTMLInputElement>("input")!;
  await act(async () => checkbox.click());
  expect(checkbox.checked).toBe(true);
  const enter = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
  checkbox.dispatchEvent(enter);
  expect(enter.defaultPrevented).toBe(false);
  expect(bubbledKeys).toBe(0);
});
