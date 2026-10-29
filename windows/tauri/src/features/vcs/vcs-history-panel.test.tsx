import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act, type ReactNode } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import type { GitDiff } from "@/features/git/types/git.types";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot } from "./vcs-root-types";
import type { VcsBaseContent, VcsQuerySnapshot, VcsReadQuery } from "./vcs-query-types";

const opened: unknown[][] = [];
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: {
    getState: () => ({ actions: { openBuffer: (...args: unknown[]) => opened.push(args) } }),
  },
}));
mock.module("@/ui/button", () => ({
  Button: (props: { disabled?: boolean; onClick(): void; children: ReactNode }) => (
    <button disabled={props.disabled} onClick={props.onClick}>
      {props.children}
    </button>
  ),
}));
mock.module("@/ui/select", () => ({
  default: (props: {
    value: string;
    disabled?: boolean;
    onChange(value: string): void;
    options: Array<{ value: string; label: string }>;
    "aria-label": string;
  }) => (
    <select
      aria-label={props["aria-label"]}
      value={props.value}
      disabled={props.disabled}
      onChange={(event) => props.onChange(event.target.value)}
    >
      {props.options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  ),
}));
const restore = installHappyDom();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
const { createRoot } = await import("react-dom/client");
const { VcsHistoryPanel } = await import("./vcs-history-panel");
const cleanups: Array<() => void | Promise<void>> = [];
afterAll(() => {
  if (previousActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restore();
});
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await act(cleanup);
  opened.length = 0;
});

type Change = { path: string; oldPath: string | null; status: string };
async function fixture(changes: Change[] = [{ path: "a.txt", oldPath: null, status: "modified" }]) {
  const scope = { workspaceId: "fixture", workspaceRoot: "C:/fixture", incarnation: "one" };
  const view: VcsSnapshot = {
    generation: 4,
    workspaceId: scope.workspaceId,
    workspaceRoot: scope.workspaceRoot,
    detection: {
      providers: [
        {
          vcs: "svn",
          displayName: "Subversion",
          origin: { kind: "plugin", pluginID: "fixture.plugin" },
        },
      ],
      roots: ["legacy", "other"].map((id) => ({
        id,
        vcs: "svn",
        path: `${scope.workspaceRoot}/${id}`,
        mapped: false,
      })),
      ambiguous: [],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  };
  const calls: Array<{ id: string; query: VcsReadQuery }> = [];
  const cancellations: string[] = [];
  let content: Omit<VcsBaseContent, "path" | "currentPath"> = {
    content: "base\n",
    currentContent: "current\n",
    binary: false,
    currentBinary: false,
  };
  const reply = (requestId: string, rootId: string, query: VcsReadQuery): VcsQuerySnapshot => ({
    requestId,
    generation: 4,
    rootId,
    vcs: "svn",
    operation: query.operation,
    result:
      query.operation === "baseContent"
        ? { path: query.path, currentPath: query.currentPath, ...content }
        : { entries: [], nextCursor: null },
  });
  const port: VcsRootPort = {
    detect: async () => view,
    owners: async () => {
      throw new Error("unused");
    },
    close: async () => {},
    deadline: () => () => {},
    query: async (_scope, _generation, rootId, id, query) => {
      calls.push({ id, query });
      return reply(id, rootId, query);
    },
    cancelStatus: async (_scope, id) => {
      cancellations.push(id);
    },
  };
  const controller = new VcsRootController(scope, port);
  cleanups.push(async () => {
    port.cancelStatus = async () => {};
    await controller.close();
  });
  await controller.refresh();
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  let mounted = true;
  const unmount = async () => {
    if (mounted) {
      await act(() => root.unmount());
      mounted = false;
    }
  };
  cleanups.push(async () => {
    await unmount();
    host.remove();
  });
  const render = (rootId = "legacy") =>
    act(() =>
      root.render(
        <LocaleProvider language="en-US">
          <VcsHistoryPanel
            controller={controller}
            root={view.detection.roots.find((root) => root.id === rootId)!}
            changes={changes}
          />
        </LocaleProvider>,
      ),
    );
  const click = async (title: string) => {
    const button = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === title,
    );
    expect(button).toBeDefined();
    await act(() => button!.click());
  };
  await render();
  return {
    controller,
    port,
    host,
    calls,
    cancellations,
    reply,
    render,
    click,
    unmount,
    setContent: (value: typeof content) => {
      content = value;
    },
  };
}

test.each([
  { kind: "added", base: null, current: "new\n", isNew: true, isDeleted: false },
  { kind: "deleted", base: "old\n", current: null, isNew: false, isDeleted: true },
])(
  "baseline comparison renders a $kind path with an empty missing side",
  async ({ kind, base, current, isNew, isDeleted }) => {
    const f = await fixture([{ path: "a.txt", oldPath: null, status: kind }]);
    f.setContent({ content: base, currentContent: current, binary: false, currentBinary: false });
    await f.click("Compare with baseline");
    expect(opened).toHaveLength(1);
    const diff = opened[0][6] as GitDiff;
    expect(diff.is_new).toBe(isNew);
    expect(diff.is_deleted).toBe(isDeleted);
    expect(
      diff.lines
        .filter((line) => line.line_type === (isNew ? "added" : "removed"))
        .map((line) => line.content),
    ).toContain(isNew ? "new" : "old");
    expect(opened[0].slice(3, 6)).toEqual([false, true, true]);
  },
);

test("selecting a renamed change queries its original baseline and current target", async () => {
  const f = await fixture([
    { path: "a.txt", oldPath: null, status: "modified" },
    { path: "new.txt", oldPath: "old.txt", status: "renamed" },
  ]);
  await act(() => {
    const select = f.host.querySelector("select")!;
    select.value = "new.txt";
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await f.click("Read file history");
  expect(f.calls[0].query).toMatchObject({ operation: "fileHistory", path: "new.txt" });
  await f.click("Compare with baseline");
  expect(f.calls[1].query).toEqual({
    operation: "baseContent",
    path: "old.txt",
    currentPath: "new.txt",
  });
  expect(opened[0][6]).toMatchObject({
    old_path: "old.txt",
    new_path: "new.txt",
    is_renamed: true,
  });
});

test("binary comparisons report their state without creating a text diff", async () => {
  const f = await fixture();
  f.setContent({ content: null, currentContent: null, binary: true, currentBinary: true });
  await f.click("Compare with baseline");
  expect(opened).toEqual([]);
  expect(f.host.textContent).toContain("a.txt cannot be displayed as a text diff.");
});

test("failed query cleanup exposes a retry for the same native request", async () => {
  const f = await fixture();
  f.port.query = async () => {
    throw new Error("requestTimeout");
  };
  let rejectCleanup = true;
  f.port.cancelStatus = async (_scope, id) => {
    f.cancellations.push(id);
    if (rejectCleanup) throw new Error("vcs.provider.cleanupFailed");
  };
  await f.click("Read history");
  expect(f.controller.query.getSnapshot().phase).toBe("cancelFailed");
  expect(
    [...f.host.querySelectorAll("button")].find((button) => button.textContent === "Read history")!
      .disabled,
  ).toBe(true);
  rejectCleanup = false;
  await f.click("Retry cleanup");
  expect(f.cancellations).toHaveLength(2);
  expect(f.cancellations[0]).toBe(f.cancellations[1]);
  expect(f.controller.query.getSnapshot().phase).toBe("idle");
});

test.each(["root switch", "unmount"])(
  "a pending comparison is revoked on %s and cannot open a late diff",
  async (event) => {
    const f = await fixture();
    let release!: (reply: VcsQuerySnapshot) => void;
    const late = new Promise<VcsQuerySnapshot>((resolve) => {
      release = resolve;
    });
    const fallback = f.reply("late", "legacy", {
      operation: "baseContent",
      path: "a.txt",
      currentPath: "a.txt",
    });
    cleanups.push(() => release(fallback));
    f.port.query = async (_scope, _generation, _rootId, id, query) => {
      f.calls.push({ id, query });
      return late;
    };
    await f.click("Compare with baseline");
    expect(f.calls).toHaveLength(1);
    if (event === "root switch") await f.render("other");
    else await f.unmount();
    await act(() => release(f.reply(f.calls[0].id, "legacy", f.calls[0].query)));
    expect(f.cancellations).toEqual([f.calls[0].id]);
    expect(opened).toEqual([]);
    expect(f.controller.query.busy).toBe(false);
  },
);
