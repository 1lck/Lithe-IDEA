import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { GitFetchStatus } from "./git-fetch-status";
import { useGitConsoleStore } from "../stores/git-console.store";
import type { GitFetchProgress } from "../services/git-fetch-progress";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let previousFetches: GitFetchProgress[];
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousFetches = useGitConsoleStore.getState().fetches;
  useGitConsoleStore.setState({ fetches: [] });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    useGitConsoleStore.setState({ fetches: previousFetches });
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

const render = async (language: "en-US" | "zh-CN" = "en-US") =>
  act(async () => {
    root.render(
      <LocaleProvider language={language}>
        <GitFetchStatus />
      </LocaleProvider>,
    );
  });
const publish = async (fetches: GitFetchProgress[]) =>
  act(async () => {
    useGitConsoleStore.setState({ fetches });
  });

test("Footer switches between unknown and actual phase progress, then hides when idle", async () => {
  await render();
  expect(container.querySelector('[role="progressbar"]')).toBeNull();
  await publish([{ operationId: "fetch", root: "C:/repo" }]);
  let bar = container.querySelector<HTMLElement>('[role="progressbar"]')!;
  expect(bar.hasAttribute("aria-valuenow")).toBe(false);
  expect(
    container.querySelector('[data-slot="progress-indicator"][data-indeterminate]'),
  ).not.toBeNull();
  await publish([
    { operationId: "fetch", root: "C:/repo", phase: { stage: "receiving", percent: 42 } },
  ]);
  bar = container.querySelector<HTMLElement>('[role="progressbar"]')!;
  expect(bar.getAttribute("aria-valuenow")).toBe("42");
  expect(bar.getAttribute("aria-label")).toContain("Receiving objects");
  expect(
    container.querySelector<HTMLElement>('[data-slot="progress-indicator"]')?.style.width,
  ).toBe("42%");
  await publish([]);
  expect(container.querySelector('[role="progressbar"]')).toBeNull();
});

test("Footer remount retains active operations and localizes the stage without aggregating percentages", async () => {
  await publish([
    { operationId: "first", root: "C:/repo-a", phase: { stage: "receiving", percent: 90 } },
    { operationId: "second", root: "C:/repo-b", phase: { stage: "counting", percent: 10 } },
  ]);
  await render("zh-CN");
  expect(container.textContent).toContain("正在获取 (2): 统计对象");
  expect(container.querySelector('[role="progressbar"]')?.getAttribute("aria-valuenow")).toBe("10");
  await act(async () => root.render(null));
  await render("zh-CN");
  expect(container.querySelector('[role="progressbar"]')?.getAttribute("aria-label")).toContain(
    "C:/repo-b",
  );
});
