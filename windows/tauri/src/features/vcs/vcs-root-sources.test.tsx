import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act, type ReactNode } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsOwnership, VcsRootPort, VcsSnapshot, VcsStatusSnapshot } from "./vcs-root-types";

let activeFile = "C:/fixture/vcs/legacy/a.txt";
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: (selector: (state: unknown) => unknown) =>
    selector({
      activeBufferId: "file",
      buffers: [{ id: "file", type: "editor", path: activeFile }],
    }),
}));
// The shared Select owns its interaction tests; this lane exercises the
// production source/ownership component's connection to the actual controller.
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
mock.module("@/ui/button", () => ({
  Button: (props: { disabled?: boolean; onClick(): void; children: ReactNode }) => (
    <button disabled={props.disabled} onClick={props.onClick}>
      {props.children}
    </button>
  ),
}));
const restore = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { VcsRootSources } = await import("./vcs-root-sources");
afterAll(restore);
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await act(cleanup);
});
async function fixture() {
  const scope = { workspaceId: "fixture", workspaceRoot: "C:/fixture/vcs", incarnation: "one" };
  const view: VcsSnapshot = {
    generation: 1,
    workspaceId: scope.workspaceId,
    workspaceRoot: scope.workspaceRoot,
    detection: {
      providers: [
        { vcs: "git", displayName: "Git", origin: { kind: "builtIn" } },
        {
          vcs: "svn",
          displayName: "Subversion",
          origin: { kind: "plugin", pluginID: "fixture.plugin" },
        },
      ],
      roots: [
        { id: "", vcs: "git", path: scope.workspaceRoot, mapped: false },
        { id: "legacy", vcs: "svn", path: `${scope.workspaceRoot}/legacy`, mapped: false },
      ],
      ambiguous: [{ id: "mixed", vcs: ["git", "svn"] }],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  };
  const queries: string[][] = [];
  const port: VcsRootPort = {
    detect: async () => view,
    close: async () => {},
    deadline: () => () => {},
    owners: async (_scope, generation, paths): Promise<VcsOwnership> => {
      queries.push(paths);
      return {
        generation,
        owners: paths.map((path) => ({ path, root: "legacy" })),
        commonRoot: view.detection.roots[1],
        complete: true,
      };
    },
  };
  const controller = new VcsRootController(scope, port);
  cleanups.push(() => {
    port.cancelStatus = async () => {};
    return controller.close();
  });
  await controller.refresh();
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  cleanups.push(() => {
    root.unmount();
    host.remove();
  });
  const render = () =>
    act(async () =>
      root.render(
        <LocaleProvider language="en-US">
          <VcsRootSources controller={controller} />
        </LocaleProvider>,
      ),
    );
  return { controller, view, port, render, host, queries };
}

test("ordinary version control sources render plugin roots and query the current file through native ownership", async () => {
  activeFile = "C:/fixture/vcs/legacy/a.txt";
  const f = await fixture();
  await f.render();
  expect(f.queries).toEqual([["legacy/a.txt"]]);
  expect(f.host.textContent).toContain("Subversion");
  expect(f.host.textContent).toContain("Version control is ambiguous for mixed");
  expect(f.host.textContent).toContain("Current file: Subversion · legacy");
  expect([...f.host.querySelectorAll("option")].map((option) => option.value)).toEqual([
    "root:legacy",
  ]);
});

test("an ambiguous current file displays no owner and an outside file is never queried", async () => {
  activeFile = "C:/fixture/vcs/mixed/a.txt";
  const f = await fixture();
  let requests = 0;
  f.port.owners = async (_scope, generation, paths) => {
    requests++;
    return {
      generation,
      owners: paths.map((path) => ({ path, root: null })),
      commonRoot: null,
      complete: true,
    };
  };
  await f.render();
  expect(f.host.textContent).toContain("Current file has no unambiguous version control owner");
  expect(requests).toBe(1);
  activeFile = "C:/fixture/outside/a.txt";
  await f.render();
  expect(f.host.textContent).not.toContain("Current file:");
  expect(requests).toBe(1);
});

test("revocation clears the source selector and ownership display immediately", async () => {
  activeFile = "C:/fixture/vcs/legacy/a.txt";
  const f = await fixture();
  await f.render();
  await act(async () => f.controller.invalidate());
  expect(f.host.querySelector('[data-testid="vcs-root-sources"]')).toBeNull();
  expect(f.host.textContent).not.toContain("Subversion");
});

test("the ordinary source pane reads status explicitly and renders only its independent read-only projection", async () => {
  const f = await fixture();
  const calls: unknown[][] = [];
  f.port.status = async (...args) => {
    calls.push(args);
    return {
      requestId: args[3],
      generation: args[1],
      rootId: args[2],
      vcs: "svn",
      result: {
        head: null,
        changes: [{ path: "a.txt", oldPath: null, status: "modified", flags: [] }],
        truncated: true,
      },
    };
  };
  f.port.cancelStatus = async () => {};
  await f.render();
  expect(calls).toHaveLength(0);
  const read = f.host.querySelector("button")!;
  expect(read.textContent).toBe("Read status");
  await act(async () => read.click());
  expect(calls[0]?.slice(0, 3)).toEqual([f.controller.scope, 1, "legacy"]);
  expect(f.host.textContent).toContain("Modified");
  expect(f.host.textContent).toContain("a.txt");
  expect(f.host.textContent).toContain("The provider returned an incomplete change list");
  expect([...f.host.querySelectorAll("button")].map((button) => button.textContent)).toEqual([
    "Read status",
  ]);
});

test("failed cleanup keeps Stop retry visible and prevents another status read", async () => {
  const f = await fixture();
  let release!: (value: VcsStatusSnapshot) => void;
  const pending = new Promise<VcsStatusSnapshot>((resolve) => {
    release = resolve;
  });
  cleanups.push(() =>
    release({
      requestId: "late",
      generation: 1,
      rootId: "legacy",
      vcs: "svn",
      result: { head: null, changes: [], truncated: false },
    }),
  );
  f.port.status = () => pending;
  f.port.cancelStatus = async () => {
    throw new Error("vcs.provider.cleanupFailed");
  };
  await f.render();
  await act(async () => f.host.querySelector("button")!.click());
  expect(f.host.textContent).toContain("Reading changes…");
  expect(f.host.querySelector("select")!.disabled).toBe(true);
  await act(async () => f.host.querySelectorAll("button")[1].click());
  expect(f.host.textContent).toContain("Provider cleanup could not be confirmed");
  expect(f.host.querySelector("button")!.disabled).toBe(true);
  expect(f.host.querySelectorAll("button")[1].textContent).toBe("Retry cleanup");
  f.port.cancelStatus = async () => {};
  await act(async () => f.host.querySelectorAll("button")[1].click());
  expect(f.host.querySelector("button")!.disabled).toBe(false);
  expect(f.host.textContent).not.toContain("Provider cleanup could not be confirmed");
});
