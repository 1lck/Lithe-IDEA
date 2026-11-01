import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { AgentHistoryList } from "./agent-history-list";

const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let exported: string[][];

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  exported = [];
});

afterEach(async () => {
  try { await act(async () => root.unmount()); }
  finally {
    container.remove();
    restoreDom();
    if (previousActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
});

function render() {
  act(() => root.render(<LocaleProvider language="en-US"><AgentHistoryList
    sessions={[
      { id: "a", title: "Native chat", updatedAt: null, modelProvider: "native-provider" },
      { id: "b", title: "Other chat", updatedAt: null, modelProvider: "previous-provider" },
      { id: "unknown", title: "Unknown chat", updatedAt: null },
    ]}
    archive={{ supported: true, sessions: [
      { id: "archive", title: "Archived native chat", updatedAt: null, modelProvider: "archive-only-provider" },
    ], loading: false, complete: true, error: null, restoringIDs: [], canRefresh: true,
    onRefresh() {}, onRestore: async () => true }}
    metadata={{}} conversations={{}} isRefreshing={false} error={null} canRefresh
    onRefresh={() => {}} onSelect={() => {}} onRename={async () => true}
    onSetFavorite={() => {}} onSetHidden={() => {}}
    isExporting={false} onExport={(ids) => exported.push(ids)} canExportSession={() => true}
  /></LocaleProvider>));
}

function button(text: string): HTMLButtonElement {
  const found = [...container.querySelectorAll("button")].find((entry) => entry.textContent === text);
  if (!found) throw new Error(`Missing history action: ${text}`);
  return found;
}

function selectProvider(value: string | null) {
  const select = container.querySelector<HTMLSelectElement>('select[aria-label="Conversation provider"]');
  if (!select) throw new Error("Missing provider selector");
  act(() => {
    select.value = value === null ? "all" : JSON.stringify(value);
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

test("provider selector includes archive-only and unknown sources, and restores all without routing changes", () => {
  render();
  expect(container.textContent).toContain("4 conversations");
  const select = container.querySelector<HTMLSelectElement>('select[aria-label="Conversation provider"]')!;
  expect([...select.options].map((entry) => entry.text)).toEqual([
    "All providers", "archive-only-provider", "native-provider", "previous-provider", "Unknown provider",
  ]);
  selectProvider("native-provider");
  expect(container.textContent).toContain("1 conversations");
  expect(container.textContent).toContain("Native chat");
  expect(container.textContent).not.toContain("Other chat");
  expect(container.textContent).not.toContain("Unknown chat");
  selectProvider("archive-only-provider");
  expect(container.textContent).toContain("Archived native chat");
  expect(container.textContent).toContain("1 conversations");
  selectProvider("");
  expect(container.textContent).toContain("Unknown chat");
  expect(container.textContent).not.toContain("Native chat");
  selectProvider(null);
  expect(container.textContent).toContain("4 conversations");
  expect(container.textContent).toContain("Other chat");
});

test("changing provider clears bulk selection and select-all affects only visible active rows", () => {
  render();
  act(() => button("Select").click());
  act(() => button("Select all").click());
  expect(container.textContent).toContain("3 selected");
  selectProvider("native-provider");
  expect(container.textContent).toContain("0 selected");
  act(() => button("Select all").click());
  act(() => button("Export conversations").click());
  expect(exported).toEqual([["a"]]);
});
