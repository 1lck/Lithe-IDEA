import {
  assignChangelist,
  EMPTY_CHANGELISTS,
  type LocalChangelists,
} from "../../utils/git-changelists";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { createSingleFileWorkingTreeDiff } from "../../utils/working-tree-multi-diff";
import { createRoot, type Root } from "react-dom/client";
import * as virtual from "@tanstack/react-virtual";
import * as statusApi from "../../api/git-status-api";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import GitStatusPanel from "./git-status-panel";
import type { GitFile } from "../../types/git.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let staging: ReturnType<typeof spyOn<typeof statusApi, "setFilesStaged">>;
let virtualizer: ReturnType<typeof spyOn<typeof virtual, "useVirtualizer">>;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let previousGetAnimations: PropertyDescriptor | undefined;
let previousBuffers: Pick<ReturnType<typeof useBufferStore.getState>, "buffers" | "activeBufferId">;
let scrollRequests: Array<{ index: number; align?: string }>;
let previousFolderView: boolean;
beforeEach(() => {
  restoreDom = installHappyDom();
  // Base UI measures scroll geometry after animations. This DOM fixture has
  // no animations; provide the browser API that happy-dom does not implement.
  previousGetAnimations = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "getAnimations");
  Object.defineProperty(HTMLElement.prototype, "getAnimations", {
    configurable: true,
    value: () => [],
  });
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousFolderView = useSettingsStore.getState().settings.gitChangesFolderView;
  useSettingsStore.setState((state) => ({
    settings: { ...state.settings, gitChangesFolderView: true },
  }));
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  const bufferState = useBufferStore.getState();
  previousBuffers = { buffers: bufferState.buffers, activeBufferId: bufferState.activeBufferId };
  useBufferStore.setState({ buffers: [], activeBufferId: null });
  scrollRequests = [];
  staging = spyOn(statusApi, "setFilesStaged").mockResolvedValue(true);
  // Expose visible rows without relying on browser layout measurements in happy-dom.
  virtualizer = spyOn(virtual, "useVirtualizer").mockImplementation(((
    options: Parameters<typeof virtual.useVirtualizer>[0],
  ) => ({
    getVirtualItems: () =>
      Array.from({ length: options.count }, (_, index) => ({ index, size: 32, start: index * 32 })),
    getTotalSize: () => options.count * 32,
    scrollToIndex: (index: number, options?: { align?: string }) => {
      scrollRequests.push({ index, ...options });
    },
  })) as unknown as typeof virtual.useVirtualizer);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    staging.mockRestore();
    virtualizer.mockRestore();
    useBufferStore.setState(previousBuffers);
    useSettingsStore.setState((state) => ({
      settings: { ...state.settings, gitChangesFolderView: previousFolderView },
    }));
    container.remove();
    if (previousGetAnimations) {
      Object.defineProperty(HTMLElement.prototype, "getAnimations", previousGetAnimations);
    } else Reflect.deleteProperty(HTMLElement.prototype, "getAnimations");
    restoreDom();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});
const render = async (
  files: GitFile[],
  changelists?: LocalChangelists,
  options: {
    onFileSelect?: (path: string, staged: boolean) => void;
    onPreviewFile?: (path: string, staged: boolean) => void;
    stagingDisabled?: boolean;
  } = {},
) => {
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
          {...options}
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

const preview = async (file: GitFile, options: { history?: boolean; loading?: boolean } = {}) => {
  const target = {
    repoPath: file.repositoryPath!,
    filePath: file.repositoryRelativePath!,
    untracked: false,
  };
  const data = createSingleFileWorkingTreeDiff({
    repoPath: target.repoPath,
    target,
    fileKey: `unstaged:${file.path}`,
    diff: null,
    commitPreview: true,
  });
  await act(async () =>
    useBufferStore.setState({
      activeBufferId: "commit-preview",
      buffers: [
        createPaneContent("commit-preview", {
          type: "diff",
          path: "diff://preview",
          name: "Commit",
          content: "",
          diffData: {
            ...data,
            commitHash: options.history ? "revision" : "working-tree",
            isLoading: options.loading ?? false,
          },
        }),
      ],
    }),
  );
};
const selectedNames = () =>
  [...container.querySelectorAll('[role="treeitem"][aria-selected="true"]')].map(
    (row) => row.textContent,
  );

test("Commit selection and virtual scrolling follow both directions without changing inclusion or stealing focus", async () => {
  const first = file("A", "a.ts"),
    next = file("B", "b.ts");
  await render([first, next]);
  const editor = document.createElement("textarea");
  container.append(editor);
  editor.focus();
  await preview(first);
  expect(selectedNames()).toHaveLength(1);
  expect(selectedNames()[0]).toContain("a.ts");
  await preview(next);
  expect(selectedNames()).toHaveLength(1);
  expect(selectedNames()[0]).toContain("b.ts");
  const row = container
    .querySelector('[aria-label="Include b.ts in commit"]')!
    .closest("[data-git-status-row-index]")!;
  expect(scrollRequests[scrollRequests.length - 1]).toEqual({
    index: Number(row.getAttribute("data-git-status-row-index")),
    align: "auto",
  });
  const scrollCount = scrollRequests.length;
  // Refreshing the same comparison must not repeatedly pull the list back into view.
  await preview(next);
  expect(scrollRequests).toHaveLength(scrollCount);
  await preview(first);
  expect(selectedNames()[0]).toContain("a.ts");
  expect(document.activeElement).toBe(editor);
  expect(staging).not.toHaveBeenCalled();
});

test("preview selection reveals collapsed repository, section and compact folders, ignoring foreign history and loading", async () => {
  const selected = file("B", "b.ts"),
    other = file("A", "a.ts");
  const section = "C:/workspace/B:default:changelist";
  function Harness() {
    const [collapsedSections, setSections] = useState(
      new Set(["repository:C:/workspace/B", section]),
    );
    const [collapsedFolders, setFolders] = useState(new Set([`${section}:src`]));
    return (
      <GitStatusPanel
        files={[other, selected]}
        repositoryCount={2}
        repoPath="C:/workspace/A"
        collapsedSections={collapsedSections}
        onCollapsedSectionsChange={setSections}
        collapsedFolders={collapsedFolders}
        onCollapsedFoldersChange={setFolders}
        onStagingRefresh={async () => {}}
      />
    );
  }
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <Harness />
      </LocaleProvider>,
    ),
  );
  await preview(selected, { history: true });
  expect(selectedNames()).toHaveLength(0);
  await preview(selected, { loading: true });
  expect(selectedNames()).toHaveLength(0);
  await preview({ ...selected, repositoryPath: "C:/foreign" });
  expect(selectedNames()).toHaveLength(0);
  await preview(selected);
  expect(selectedNames()).toHaveLength(1);
  expect(selectedNames()[0]).toContain("b.ts");
  expect(scrollRequests[scrollRequests.length - 1]?.align).toBe("auto");
  expect(staging).not.toHaveBeenCalled();
});

test("file checkboxes stage in their owner repository, independently of the active root", async () => {
  await render([file("A", "a.ts"), file("B", "b.ts")]);
  expect(container.querySelector('[role=treeitem][title="C:/workspace/A"]')?.textContent).toBe(
    "A1",
  );
  expect(container.querySelector('[role=treeitem][title="C:/workspace/B"]')?.textContent).toBe(
    "B1",
  );
  const checkbox = container.querySelector<HTMLElement>('[aria-label="Include b.ts in commit"]');
  expect(checkbox).not.toBeNull();
  await act(async () => checkbox!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/B", ["src/b.ts"], true);
});

test("keeps the repository header with one changed root and excludes dirty-only submodule pointers", async () => {
  await render([file("B"), { ...file("B", "child"), canToggleStaging: false }]);
  expect(container.querySelector('[role=treeitem][title="C:/workspace/B"]')?.textContent).toBe(
    "B2",
  );
  const dirty = container.querySelector<HTMLElement>('[aria-label="Include child in commit"]');
  expect(dirty?.hasAttribute("disabled") || dirty?.getAttribute("aria-disabled") === "true").toBe(
    true,
  );
  const headerCheckbox = container.querySelector<HTMLElement>(
    '[aria-label="Include folder B in commit"]',
  );
  expect(headerCheckbox).not.toBeNull();
  await act(async () => headerCheckbox!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/B", ["src/hello.ts"], true);
});

test("toolbar preview opens the complete first change independently of the row-click action", async () => {
  const first = { ...file("A", "first.ts"), staged: true, worktree: true };
  const rowClicks: string[] = [];
  const previews: Array<{ path: string; staged: boolean }> = [];
  await render([first, file("B", "next.ts")], undefined, {
    onFileSelect: (path) => rowClicks.push(path),
    onPreviewFile: (path, staged) => previews.push({ path, staged }),
  });
  const previewButton = container.querySelector<HTMLButtonElement>(
    '[aria-label="Preview first change"]',
  );
  expect(previewButton?.disabled).toBe(false);
  await act(async () => previewButton!.click());
  expect(previews).toEqual([{ path: first.path, staged: false }]);
  expect(rowClicks).toEqual([]);
  expect(staging).not.toHaveBeenCalled();
});

test("commit review locks file and repository inclusion and bulk staging", async () => {
  await render([file("A", "locked.ts")], undefined, { stagingDisabled: true });
  for (const label of [
    "Include locked.ts in commit",
    "Include folder A in commit",
    "Stage all changes",
  ]) {
    const control = container.querySelector<HTMLButtonElement>(`[aria-label="${label}"]`);
    expect(control).not.toBeNull();
    expect(control!.disabled || control!.getAttribute("aria-disabled") === "true").toBe(true);
    await act(async () => control!.click());
  }
  expect(staging).not.toHaveBeenCalled();
});

test("one ChangeList contains both tracked and unversioned files, matching Swift grouping", async () => {
  await render([file("A", "tracked.ts"), { ...file("A", "new.ts"), status: "untracked" }]);
  const groups = container.querySelectorAll('[data-git-status-section="changelist"]');
  expect(groups).toHaveLength(1);
  expect(groups[0]?.textContent).toContain("Default ChangeList");
  expect(groups[0]?.textContent).toContain("2 files");
  const include = container.querySelector<HTMLElement>(
    '[aria-label="Include folder Default ChangeList in commit"]',
  );
  await act(async () => include!.click());
  expect(staging).toHaveBeenCalledWith("C:/workspace/A", ["src/new.ts", "src/tracked.ts"], true);
});

test("a group node checkbox includes all of its files and shows a mixed state", async () => {
  await render([file("A", "one.ts"), { ...file("A", "two.ts"), staged: true }]);
  const groupCheckbox = container.querySelector<HTMLElement>(
    '[aria-label="Include folder Default ChangeList in commit"]',
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
