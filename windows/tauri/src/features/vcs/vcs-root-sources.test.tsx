import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsOwnership, VcsRootPort, VcsSnapshot } from "./vcs-root-types";

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
    onChange(value: string): void;
    options: Array<{ value: string; label: string }>;
    "aria-label": string;
  }) => (
    <select
      aria-label={props["aria-label"]}
      value={props.value}
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
  cleanups.push(() => controller.close());
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
