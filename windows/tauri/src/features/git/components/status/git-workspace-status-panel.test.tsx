import {
  assignChangelist,
  EMPTY_CHANGELISTS,
  type LocalChangelists,
} from "../../utils/git-changelists";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as virtual from "@tanstack/react-virtual";
import * as statusApi from "../../api/git-status-api";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import GitStatusPanel from "./git-status-panel";
import type { GitFile } from "../../types/git.types";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let staging: ReturnType<typeof spyOn<typeof statusApi, "setFilesStaged">>;
let virtualizer: ReturnType<typeof spyOn<typeof virtual, "useVirtualizer">>;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let previousGetAnimations: PropertyDescriptor | undefined;
beforeEach(() => {
  restoreDom = installHappyDom();
  // Base UI measures scroll geometry after animations. This DOM fixture has
  // no animations; provide the browser API that happy-dom does not implement.
  previousGetAnimations = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "getAnimations");
  Object.defineProperty(HTMLElement.prototype, "getAnimations", { configurable: true, value: () => [] });
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  staging = spyOn(statusApi, "setFilesStaged").mockResolvedValue(true);
  // Expose visible rows without relying on browser layout measurements in happy-dom.
  virtualizer = spyOn(virtual, "useVirtualizer").mockImplementation(((
    options: Parameters<typeof virtual.useVirtualizer>[0],
  ) => ({
    getVirtualItems: () =>
      Array.from({ length: options.count }, (_, index) => ({ index, size: 32, start: index * 32 })),
    getTotalSize: () => options.count * 32,
    scrollToIndex: () => {},
  })) as unknown as typeof virtual.useVirtualizer);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    staging.mockRestore();
    virtualizer.mockRestore();
    container.remove();
    if (previousGetAnimations) {
      Object.defineProperty(HTMLElement.prototype, "getAnimations", previousGetAnimations);
    } else Reflect.deleteProperty(HTMLElement.prototype, "getAnimations");
    restoreDom();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});
const render = async (files: GitFile[], changelists?: LocalChangelists) => {
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitStatusPanel
          files={files}
          changelists={changelists}
          repositoryCount={2}
          repoPath="C:/workspace/A"
          collapsedFolders={new Set()}
          onCollapsedFoldersChange={() => {}}
          collapsedSections={new Set()}
          onCollapsedSectionsChange={() => {}}
          onStagingRefresh={async () => {}}
        />
      </LocaleProvider>,
    ),
  );
};
const file = (repository: string, name = "hello.ts"): GitFile => ({
  path: `${repository}/src/${name}`,
  repositoryPath: `C:/workspace/${repository}`,
  repositoryRelativePath: `src/${name}`,
  status: "modified",
  staged: false,
  canToggleStaging: true,
});

test("file checkboxes stage in their owner repository, independently of the active root", async () => {
  await render([file("A", "a.ts"), file("B", "b.ts")]);
  expect(container.textContent).toContain("C:/workspace/A");
  expect(container.textContent).toContain("C:/workspace/B");
  const checkbox = container.querySelector<HTMLElement>('[aria-label="Include b.ts in commit"]');
  expect(checkbox).not.toBeNull();
  await act(async () => checkbox!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/B", ["src/b.ts"], true);
});

test("keeps the repository header with one changed root and excludes dirty-only submodule pointers", async () => {
  await render([file("B"), { ...file("B", "child"), canToggleStaging: false }]);
  expect(container.textContent).toContain("C:/workspace/B");
  const dirty = container.querySelector<HTMLElement>('[aria-label="Include child in commit"]');
  expect(dirty?.hasAttribute("disabled") || dirty?.getAttribute("aria-disabled") === "true").toBe(
    true,
  );
  const headerCheckbox = container.querySelector<HTMLElement>(
    '[aria-label="Include folder C:/workspace/B in commit"]',
  );
  expect(headerCheckbox).not.toBeNull();
  await act(async () => headerCheckbox!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/B", ["src/hello.ts"], true);
});

test("groups files under IntelliJ's Changes and Unversioned Files nodes", async () => {
  await render([file("A", "tracked.ts"), { ...file("A", "new.ts"), status: "untracked" }]);
  const changes = container.querySelector('[data-git-status-section="tracked"]');
  const unversioned = container.querySelector('[data-git-status-section="untracked"]');
  expect(changes?.textContent).toContain("Changes");
  expect(changes?.textContent).toContain("1 file");
  expect(unversioned?.textContent).toContain("Unversioned Files");
  expect(container.textContent).not.toContain("Tracked");
  expect(container.textContent).not.toContain("Untracked");
});

test("a group node checkbox includes all of its files and shows a mixed state", async () => {
  await render([file("A", "one.ts"), { ...file("A", "two.ts"), staged: true }]);
  const groupCheckbox = container.querySelector<HTMLElement>(
    '[aria-label="Include folder Changes in commit"]',
  );
  expect(groupCheckbox?.hasAttribute("data-indeterminate")).toBe(true);
  await act(async () => groupCheckbox!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/A", ["src/one.ts", "src/two.ts"], true);
});

test("the include-in-commit checkbox sits before the file name, not after it", async () => {
  await render([file("A", "left.ts")]);
  const checkbox = container.querySelector<HTMLElement>('[aria-label="Include left.ts in commit"]');
  const row = checkbox?.closest("[data-sidebar-tree-row]");
  const label = Array.from(row?.querySelectorAll("span") ?? []).find(
    (span) => span.textContent === "left.ts",
  );
  expect(row).not.toBeNull();
  expect(label).not.toBeUndefined();
  // The checkbox overlays a reserved slot placed ahead of the icon and name.
  expect(row!.querySelector("[data-sidebar-tree-leading-slot]")).not.toBeNull();
  expect(
    checkbox!.compareDocumentPosition(row!.querySelector("[role=treeitem]")!) &
      Node.DOCUMENT_POSITION_FOLLOWING,
  ).toBeTruthy();
});

test("View Options switches between the directory tree and a flat list in two clicks", async () => {
  const settings = await import("@/features/settings/stores/settings.store");
  const updateSetting = spyOn(
    settings.useSettingsStore.getState().actions,
    "updateSetting",
  ).mockResolvedValue(undefined as never);
  // The dropdown positions itself with ResizeObserver, which happy-dom lacks.
  const globals = globalThis as { ResizeObserver?: unknown };
  const previousResizeObserver = globals.ResizeObserver;
  globals.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  try {
    await render([file("A", "flat.ts")]);
    const current = settings.useSettingsStore.getState().settings.gitChangesFolderView;
    const viewOptions = container.querySelector<HTMLElement>('[aria-label="View Options"]');
    await act(async () => viewOptions!.click());
    const target = Array.from(document.querySelectorAll<HTMLElement>("[role=menuitem]")).find(
      (item) => item.textContent?.includes(current ? "Flat List" : "Directory"),
    );
    expect(target).not.toBeUndefined();
    await act(async () => target!.click());
    expect(updateSetting).toHaveBeenCalledWith("gitChangesFolderView", !current);
  } finally {
    updateSetting.mockRestore();
    globals.ResizeObserver = previousResizeObserver;
  }
});

test("bulk and repository staging only include the active changelist, while named groups remain visible", async () => {
  const config = file("A", "application.yaml");
  const feature = file("A", "feature.ts");
  const lists = assignChangelist(
    {
      ...EMPTY_CHANGELISTS,
      lists: [...EMPTY_CHANGELISTS.lists, { id: "local", name: "Local only" }],
    },
    [config],
    "local",
  );
  await render([config, feature], lists);
  expect(container.textContent).toContain("Local only");
  const all = container.querySelector<HTMLElement>(
    '[aria-label="Stage all changes in the active changelist"]',
  );
  expect(all).not.toBeNull();
  await act(async () => all!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/A", ["src/feature.ts"], true);
  expect(staging.mock.calls.flatMap((call) => call[1])).not.toContain("src/application.yaml");
});

test("named group selection stays inside that group", async () => {
  const config = file("A", "application.yaml");
  const lists = assignChangelist(
    {
      ...EMPTY_CHANGELISTS,
      lists: [...EMPTY_CHANGELISTS.lists, { id: "local", name: "Local only" }],
    },
    [config],
    "local",
  );
  await render([config, file("A", "feature.ts")], lists);
  const checkbox = container.querySelector<HTMLElement>(
    '[aria-label="Include folder Local only in commit"]',
  );
  await act(async () => checkbox!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/A", ["src/application.yaml"], true);
});
