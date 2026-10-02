import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { GitLogColumnResizeHandle } from "@/features/git/components/log/git-log-column-resize-handle";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useGitLogPreferencesStore } from "../stores/git-log-preferences.store";
import { GIT_LOG_COLUMN_DEFAULT_WIDTHS } from "../utils/git-log-columns";
import { useGitLogColumnResize } from "./use-git-log-column-resize";

let rowClicks = 0;
// Manual animation-frame queue so live widths are applied deterministically, without real timers.
let pendingFrames = new Map<number, FrameRequestCallback>();
let nextFrameHandle = 1;
const frameScheduler = {
  scheduleFrame: (callback: FrameRequestCallback) => {
    const handle = nextFrameHandle++;
    pendingFrames.set(handle, callback);
    return handle;
  },
  cancelFrame: (handle: number) => {
    pendingFrames.delete(handle);
  },
};

// Mirrors the table: one scroll container whose CSS variables drive every row's column widths.
function Harness() {
  const scrollRef = useRef<HTMLDivElement>(null);
  const { columnStyle, activeColumn, startResize } = useGitLogColumnResize(
    scrollRef,
    frameScheduler,
  );

  return (
    <LocaleProvider language="en-US">
      <div ref={scrollRef} data-testid="scroll" style={columnStyle}>
        <div data-testid="row" onClick={() => (rowClicks += 1)}>
          <div data-testid="author-cell">
            <GitLogColumnResizeHandle column="author" onStartResize={startResize} />
          </div>
          <div data-testid="date-cell">
            <GitLogColumnResizeHandle column="date" onStartResize={startResize} />
          </div>
        </div>
      </div>
      <span data-testid="active">{activeColumn ?? "none"}</span>
    </LocaleProvider>
  );
}

function pointerEvent(type: string, init: { clientX: number; button?: number }) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  return Object.assign(event, { button: 0, ...init });
}

const flushFrames = () => {
  const frames = [...pendingFrames.values()];
  pendingFrames = new Map();
  for (const frame of frames) frame(0);
};

let restoreDom: () => void;
let container: HTMLElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  rowClicks = 0;
  pendingFrames = new Map();
  useGitLogPreferencesStore.setState({
    authorColumnWidth: GIT_LOG_COLUMN_DEFAULT_WIDTHS.author,
    dateColumnWidth: GIT_LOG_COLUMN_DEFAULT_WIDTHS.date,
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root.render(<Harness />);
  });
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
  });
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

const query = (testId: string) =>
  container.querySelector<HTMLElement>(`[data-testid="${testId}"]`) as HTMLElement;
const handle = (cellTestId: string) =>
  query(cellTestId).querySelector<HTMLElement>('[role="separator"]') as HTMLElement;

test("dragging a column's left edge leftwards widens it live and persists once on release", async () => {
  const scroll = query("scroll");
  expect(scroll.style.getPropertyValue("--git-log-author-width")).toBe("112px");

  await act(async () => {
    handle("author-cell").dispatchEvent(pointerEvent("pointerdown", { clientX: 300 }));
  });
  expect(query("active").textContent).toBe("author");

  await act(async () => {
    document.dispatchEvent(pointerEvent("pointermove", { clientX: 260 }));
    flushFrames();
  });
  // The live width lands on the DOM, but nothing is written to the store mid-drag.
  expect(scroll.style.getPropertyValue("--git-log-author-width")).toBe("152px");
  expect(useGitLogPreferencesStore.getState().authorColumnWidth).toBe(112);

  await act(async () => {
    document.dispatchEvent(pointerEvent("pointerup", { clientX: 260 }));
  });
  expect(useGitLogPreferencesStore.getState().authorColumnWidth).toBe(152);
  expect(useGitLogPreferencesStore.getState().dateColumnWidth).toBe(144);
  expect(scroll.style.getPropertyValue("--git-log-author-width")).toBe("152px");
  expect(query("active").textContent).toBe("none");
});

test("the date column resizes independently and respects its bounds", async () => {
  const scroll = query("scroll");

  await act(async () => {
    handle("date-cell").dispatchEvent(pointerEvent("pointerdown", { clientX: 500 }));
  });
  await act(async () => {
    document.dispatchEvent(pointerEvent("pointermove", { clientX: -5000 }));
    flushFrames();
  });
  expect(scroll.style.getPropertyValue("--git-log-date-width")).toBe("280px");

  await act(async () => {
    document.dispatchEvent(pointerEvent("pointerup", { clientX: -5000 }));
  });
  expect(useGitLogPreferencesStore.getState().dateColumnWidth).toBe(280);
  expect(useGitLogPreferencesStore.getState().authorColumnWidth).toBe(112);
});

test("pressing the handle neither selects the row nor starts a drag with the right button", async () => {
  await act(async () => {
    handle("author-cell").dispatchEvent(pointerEvent("pointerdown", { clientX: 10, button: 2 }));
  });
  expect(query("active").textContent).toBe("none");

  await act(async () => {
    handle("author-cell").dispatchEvent(new Event("click", { bubbles: true }));
    handle("author-cell").dispatchEvent(new Event("dblclick", { bubbles: true }));
  });
  expect(rowClicks).toBe(0);
});
