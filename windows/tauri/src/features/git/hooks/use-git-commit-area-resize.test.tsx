import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  COMMIT_MESSAGE_DEFAULT_HEIGHT,
  COMMIT_MESSAGE_MAX_HEIGHT,
  COMMIT_MESSAGE_MIN_HEIGHT,
  useGitCommitPanelPreferencesStore,
} from "../stores/git-commit-panel-preferences.store";
import {
  COMMIT_MESSAGE_HEIGHT_CSS_VARIABLE,
  GIT_CHANGES_MIN_HEIGHT,
  useGitCommitAreaResize,
} from "./use-git-commit-area-resize";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let frames: FrameRequestCallback[] = [];
const frameScheduler = {
  scheduleFrame: (callback: FrameRequestCallback) => frames.push(callback),
  cancelFrame: () => undefined,
};
let changesHeight = 300;
let previousInnerHeight: number;
let previousObserver: typeof ResizeObserver;
let paneHeight = 0;
let editorHeight = 0;
let chromeHeight = 80;
const observers = new Set<() => void>();

function Probe() {
  const commitAreaRef = useRef<HTMLDivElement>(null);
  const changesRef = useRef<HTMLDivElement>(null);
  const resize = useGitCommitAreaResize(commitAreaRef, changesRef, frameScheduler);
  return (
    <div
      ref={(element) => {
        if (element) element.getBoundingClientRect = () => ({ height: paneHeight }) as DOMRect;
      }}
    >
      <div
        ref={(element) => {
          changesRef.current = element;
          if (element) {
            element.getBoundingClientRect = () => ({ height: changesHeight }) as DOMRect;
          }
        }}
      />
      <div
        ref={(element) => {
          commitAreaRef.current = element;
          if (element)
            element.getBoundingClientRect = () =>
              ({ height: editorHeight + chromeHeight }) as DOMRect;
        }}
        data-testid="commit-area"
        style={resize.commitAreaStyle}
      >
        <textarea
          ref={(element) => {
            if (element)
              element.getBoundingClientRect = () => ({ height: editorHeight }) as DOMRect;
          }}
        />
        <div
          data-testid="handle"
          tabIndex={0}
          onPointerDown={resize.startResize}
          onKeyDown={resize.handleKeyDown}
        />
      </div>
    </div>
  );
}

const handle = () => container.querySelector<HTMLElement>('[data-testid="handle"]')!;
const commitArea = () => container.querySelector<HTMLElement>('[data-testid="commit-area"]')!;
const storedHeight = () => useGitCommitPanelPreferencesStore.getState().commitMessageHeight;

const pointer = (type: string, clientY: number) => {
  const event = new Event(type, { bubbles: true, cancelable: true });
  return Object.assign(event, { button: 0, clientX: 0, clientY });
};

const drag = async (fromY: number, toY: number) => {
  await act(async () => {
    handle().dispatchEvent(pointer("pointerdown", fromY));
  });
  await act(async () => {
    document.dispatchEvent(pointer("pointermove", toY));
    const pending = frames.splice(0);
    pending[pending.length - 1]?.(0);
  });
};

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  frames = [];
  changesHeight = 300;
  paneHeight = 0;
  editorHeight = 0;
  chromeHeight = 80;
  previousObserver = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    constructor(private callback: () => void) {
      observers.add(callback);
    }
    observe() {}
    unobserve() {}
    disconnect() {
      observers.delete(this.callback);
    }
  } as unknown as typeof ResizeObserver;
  previousInnerHeight = globalThis.innerHeight;
  useGitCommitPanelPreferencesStore.setState({
    commitMessageHeight: COMMIT_MESSAGE_DEFAULT_HEIGHT,
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => root.render(<Probe />));
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  useGitCommitPanelPreferencesStore.setState({
    commitMessageHeight: COMMIT_MESSAGE_DEFAULT_HEIGHT,
  });
  globalThis.innerHeight = previousInnerHeight;
  globalThis.ResizeObserver = previousObserver;
  restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

test("dragging the divider up grows the editor and persists only when the drag ends", async () => {
  await drag(500, 460);
  expect(commitArea().style.getPropertyValue(COMMIT_MESSAGE_HEIGHT_CSS_VARIABLE)).toBe(
    `${COMMIT_MESSAGE_DEFAULT_HEIGHT + 40}px`,
  );
  // Pointer moves only touch the CSS variable; the stored height waits for pointerup.
  expect(storedHeight()).toBe(COMMIT_MESSAGE_DEFAULT_HEIGHT);

  await act(async () => document.dispatchEvent(pointer("pointerup", 460)));
  expect(storedHeight()).toBe(COMMIT_MESSAGE_DEFAULT_HEIGHT + 40);
});

test("the changes list keeps its minimum height while the commit area grows", async () => {
  await drag(500, 0);
  await act(async () => document.dispatchEvent(pointer("pointerup", 0)));
  expect(storedHeight()).toBe(
    COMMIT_MESSAGE_DEFAULT_HEIGHT + changesHeight - GIT_CHANGES_MIN_HEIGHT,
  );
});

test("dragging down never shrinks the editor below its minimum", async () => {
  await drag(500, 900);
  await act(async () => document.dispatchEvent(pointer("pointerup", 900)));
  expect(storedHeight()).toBe(COMMIT_MESSAGE_MIN_HEIGHT);
});

test("arrow keys on the focused divider resize the editor", async () => {
  await act(async () => {
    handle().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }));
  });
  expect(storedHeight()).toBe(COMMIT_MESSAGE_DEFAULT_HEIGHT + 16);
  await act(async () => {
    handle().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  });
  expect(storedHeight()).toBe(COMMIT_MESSAGE_DEFAULT_HEIGHT);
});

// The editor renders at most 60% of the viewport. After the window shrinks, the stored
// height is taller than what is on screen, and every adjustment must start from the
// visible height or the first stretch of movement would change nothing.
const shrinkViewportBelowStoredHeight = async () => {
  globalThis.innerHeight = 800;
  await act(async () => {
    useGitCommitPanelPreferencesStore.setState({ commitMessageHeight: COMMIT_MESSAGE_MAX_HEIGHT });
  });
};

test("dragging after the window shrank starts from the visible height", async () => {
  await shrinkViewportBelowStoredHeight();
  // 60% of 800px is 480px, although 640px is stored.
  await drag(500, 520);
  await act(async () => document.dispatchEvent(pointer("pointerup", 520)));
  expect(storedHeight()).toBe(460);
});

test("arrow keys after the window shrank start from the visible height", async () => {
  await shrinkViewportBelowStoredHeight();
  await act(async () => {
    handle().dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  });
  expect(storedHeight()).toBe(464);
});

// Drive layout notifications explicitly: no real browser timing or polling.
test("pane resizing and wrapped controls cap rendering without changing the saved height", async () => {
  await act(async () => useGitCommitPanelPreferencesStore.setState({ commitMessageHeight: 400 }));
  paneHeight = 500;
  editorHeight = 400;
  observers.forEach((measure) => measure());
  expect(commitArea().style.getPropertyValue("--git-commit-message-max-height")).toBe("324px");
  paneHeight = 300;
  chromeHeight = 104;
  observers.forEach((measure) => measure());
  expect(commitArea().style.getPropertyValue("--git-commit-message-max-height")).toBe("100px");
  expect(storedHeight()).toBe(400);
  // A hidden pane must not destroy the cap; showing it measures its new budget.
  paneHeight = 0;
  observers.forEach((measure) => measure());
  expect(commitArea().style.getPropertyValue("--git-commit-message-max-height")).toBe("100px");
  paneHeight = 600;
  observers.forEach((measure) => measure());
  expect(commitArea().style.getPropertyValue("--git-commit-message-max-height")).toBe("400px");
  await act(async () => root.render(null));
  expect(observers.size).toBe(0);
});

test("dragging a pane-capped editor starts at its rendered height", async () => {
  await act(async () => useGitCommitPanelPreferencesStore.setState({ commitMessageHeight: 400 }));
  paneHeight = 276;
  editorHeight = 100;
  observers.forEach((measure) => measure());
  await drag(500, 520);
  await act(async () => document.dispatchEvent(pointer("pointerup", 520)));
  expect(storedHeight()).toBe(80);
});
