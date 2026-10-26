import { afterAll, afterEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import * as events from "@tauri-apps/api/event";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { buildSystemViewId, useBuildSystemsStore } from "../build-systems-store";
import type { BuildDependenciesNative } from "../build-dependencies-native";
import type { BuildDependenciesResult, BuildDependenciesReview } from "../build-dependencies-types";
import type { BuildOutputEvent } from "../output/build-output-types";
import { useBuildOutputStore } from "../output/build-output-store";
import type { BuildView } from "../build-systems-types";
const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildSystemPane } = await import("./build-system-pane");
const { DependencyRows } = await import("./build-dependencies");
afterAll(restoreDom);
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  workspaceRuntimeRegistry.resetForTests();
});
const ROOT = "D:/fixture/dependencies-ui";
const PLUGIN = "dev.lithe.fixture.dependencies-ui";
function view(): BuildView {
  return {
    generation: 4,
    workspaceRoot: ROOT,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "fixture",
        displayName: "Fixture",
        root: ".",
        markers: [],
        modelSource: "hostIntegration",
        model: { projects: [{ id: "project", name: "App", path: "app" }] },
        options: [],
        stale: false,
        syncDigest: "sync",
        optionFingerprint: "options",
      },
    ],
  };
}
async function mount(provider = false) {
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "dependencies-ui", name: "Fixture", path: ROOT },
    "ready",
  );
  const store = useBuildSystemsStore.getStore("dependencies-ui");
  store.getState().actions.reset();
  const initial = view();
  store.getState().actions.applyView(initial, store.getState().actions.beginRequest());
  useBuildOutputStore.getStore("dependencies-ui").getState().actions.reset();
  const review: BuildDependenciesReview = {
    operationId: "dependencies-ui-1",
    pluginId: PLUGIN,
    buildSystemId: "fixture",
    workspaceRoot: ROOT,
    root: ".",
    generation: 4,
    executesProjectCode: true,
    mayUseNetwork: true,
    projectId: null,
    title: "Fixture",
    kind: "dependencies",
  };
  let sink: ((event: BuildOutputEvent) => void) | null = null;
  const native: BuildDependenciesNative = {
    windowLabel: () => "workspace-fixture",
    save: mock(async () => {}),
    sync: mock(async () => {
      const actions = store.getState().actions;
      actions.applyView(initial, actions.beginRequest());
    }),
    definition: mock(async () => ({
      tasks: [],
      programs: [
        {
          kind: "buildSystem",
          buildSystemID: "fixture",
          invocation: { executables: [{ kind: "command", command: "fixture-tool" }] },
        },
      ],
      dependencies: { source: provider ? ("provider" as const) : ("hostIntegration" as const) },
    })),
    prepare: mock(async () => review),
    execute: mock(async (): Promise<BuildDependenciesResult> => {
      const terminal = { kind: "succeeded" as const, exitCode: 0 };
      sink?.({ ...review, type: "terminal", terminal });
      return {
        ...review,
        terminal,
        dependencies: [
          {
            group: "fixture",
            name: "library",
            version: "2",
            scope: "compile",
            properties: { resolution: "omittedForConflict", selectedVersion: "3" },
            children: [{ name: "transitive", children: [] }],
          },
        ],
      };
    }),
    cancel: mock(async () => {}),
    listen: mock(async (_window, listener) => {
      sink = listener;
      return () => {
        sink = null;
      };
    }),
  };
  const listen = spyOn(events, "listen").mockResolvedValue(() => {});
  cleanups.push(() => listen.mockRestore());
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previous = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  cleanups.push(async () => {
    await act(async () => root.unmount());
    host.remove();
    if (previous === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previous;
  });
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <BuildSystemPane
          view={buildSystemViewId(PLUGIN, "fixture")}
          onClose={() => {}}
          dependenciesNative={native}
          runNative={{
            ...native,
            definition: async () => ({ tasks: [], programs: [] }),
            prepare: async () => {
              throw new Error("unexpected task");
            },
            execute: async () => ({ kind: "cancelled" }),
          }}
        />
      </LocaleProvider>,
    ),
  );
  return { host, native, store };
}
function button(container: ParentNode, text: string) {
  const value = [...container.querySelectorAll("button")].find(
    (button) => button.textContent?.trim() === text,
  );
  if (!value) throw new Error(`button missing: ${text}`);
  return value;
}

test("production pane mounts dependencies and requires review before rendering Core tree", async () => {
  const f = await mount();
  expect(f.native.prepare).not.toHaveBeenCalled();
  await act(async () => button(f.host, "Load dependencies…").click());
  expect(f.native.execute).not.toHaveBeenCalled();
  expect(document.body.textContent).toContain("Review dependency loading");
  expect(document.body.textContent).toContain("fixture-tool");
  await act(async () => button(document.body, "Approve and load").click());
  expect(f.native.execute).toHaveBeenCalledTimes(1);
  expect(f.host.textContent).toContain("fixture:library:2");
  expect(f.host.textContent).not.toContain("transitive");
  const details = f.host.querySelector("details")!;
  await act(async () => {
    details.open = true;
    details.dispatchEvent(new Event("toggle"));
  });
  expect(f.host.textContent).toContain("transitive");
  expect(f.host.textContent).toContain("omittedForConflict");
  expect(f.host.textContent).toContain("selectedVersion");
});
test("Provider source is explicitly unavailable and never prepares native work", async () => {
  const f = await mount(true);
  expect(f.host.textContent).toContain("Provider dependencies are not available yet.");
  expect(f.host.textContent).not.toContain("Load dependencies…");
  expect(f.native.prepare).not.toHaveBeenCalled();
});
test("wide dependency levels mount a bounded first page", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  cleanups.push(async () => {
    await act(async () => root.unmount());
    host.remove();
  });
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <DependencyRows
          nodes={Array.from({ length: 201 }, (_, index) => ({
            name: `artifact-${index}`,
            children: [],
          }))}
        />
      </LocaleProvider>,
    ),
  );
  expect(host.querySelectorAll("summary").length).toBe(200);
  await act(async () => button(host, "Show more dependencies").click());
  expect(host.querySelectorAll("summary").length).toBe(201);
});
