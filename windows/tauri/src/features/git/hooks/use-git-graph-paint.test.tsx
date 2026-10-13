import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useMemo } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import { GitGraphRow } from "../components/log/git-graph-row";
import { layoutGitGraph } from "../utils/git-graph-layout";
import { useGitGraphPaint } from "./use-git-graph-paint";

let restoreDom: () => void;
let root: Root;
let container: HTMLElement;
let previousSettings: ReturnType<typeof useSettingsStore.getState>["settings"];
let layoutBuilds = 0;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
const listeners = new Set<EventListenerOrEventListenerObject>();
const queries: string[] = [];

function Harness() {
  const paint = useGitGraphPaint();
  const layout = useMemo(() => {
    layoutBuilds += 1;
    return layoutGitGraph([
      {
        hash: "tip",
        shortHash: "tip",
        parentHashes: [],
        author: "fixture",
        message: "tip",
        date: "unknown",
        decorations: "HEAD -> main",
      },
    ]);
  }, []);
  return (
    <div>
      <output>{paint.rowHeight}</output>
      <GitGraphRow row={layout.rows[0]} showDecorations={false} paint={paint} />
    </div>
  );
}

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousActEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  previousSettings = useSettingsStore.getState().settings;
  useSettingsStore.setState({ settings: { ...previousSettings, uiFontSize: 13 } });
  layoutBuilds = 0;
  listeners.clear();
  queries.length = 0;
  Object.defineProperty(window, "devicePixelRatio", {
    configurable: true,
    writable: true,
    value: 1,
  });
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => {
      queries.push(query);
      return {
        addEventListener: (_: string, listener: EventListenerOrEventListenerObject) =>
          listeners.add(listener),
        removeEventListener: (_: string, listener: EventListenerOrEventListenerObject) =>
          listeners.delete(listener),
      };
    },
  });
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => root.render(<Harness />));
});

afterEach(async () => {
  await act(async () => root.unmount());
  useSettingsStore.setState({ settings: previousSettings });
  environment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

test("DPI changes repaint the real SVG without rebuilding commit layout", async () => {
  expect(container.querySelector("ellipse")?.getAttribute("rx")).toBe("4.5");
  await act(async () => {
    window.devicePixelRatio = 2;
    window.dispatchEvent(new Event("resize"));
  });
  expect(container.querySelector("ellipse")?.getAttribute("rx")).toBe("4.25");
  expect(container.querySelector("svg")?.getAttribute("height")).toBe("26");
  expect(layoutBuilds).toBe(1);
  expect(queries).toEqual(["(resolution: 1dppx)", "(resolution: 2dppx)"]);
  expect(listeners.size).toBe(1);
  await act(async () => root.unmount());
  expect(listeners.size).toBe(0);
});

test("custom UI font size changes row and node metrics together", async () => {
  expect(container.querySelector("output")?.textContent).toBe("26");
  await act(async () =>
    useSettingsStore.setState({ settings: { ...previousSettings, uiFontSize: 24 } }),
  );
  expect(container.querySelector("output")?.textContent).toBe("31");
  expect(container.querySelector("svg")?.getAttribute("height")).toBe("31");
  expect(layoutBuilds).toBe(1);
});

test("ordinary viewport resize does not repeatedly register density observers", async () => {
  await act(async () => {
    for (let index = 0; index < 50; index += 1) window.dispatchEvent(new Event("resize"));
  });
  expect(queries).toEqual(["(resolution: 1dppx)"]);
  expect(layoutBuilds).toBe(1);
});
