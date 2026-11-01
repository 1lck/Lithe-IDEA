import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { useExtensionStore } from "@/extensions/registry/extension-store";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import { uiExtensionHost } from "@/extensions/ui/services/ui-extension-host";
import * as projectDiscovery from "../utils/run-action-discovery";
import type { DeclarativePluginSummary } from "@/features/plugins/declarative-plugin-launch";
import type { RunActionItem } from "../types/run-action.types";
import * as backend from "@/config/backend-capabilities";
import * as execution from "@/features/plugins/declarative-plugin-run";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { LocaleProvider } from "@/i18n/locale-provider";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { useRunActionDiscovery } = await import("./use-run-action-discovery");
const { default: RunActionsButton } = await import("../components/run-actions-button");
const scope = { workspaceId: "r7-hook", root: "C:/fixture" };
const pluginId = "io.example.r7-execution";
const workerId = "io.example.r7-worker";
const otherFrameworkPluginId = "io.example.r7-pest";
let catalog: DeclarativePluginSummary[];
let calls: Array<{ command: string; args: Record<string, unknown> }>;
let intercept:
  | ((command: string, args: Record<string, unknown>) => Promise<unknown> | undefined)
  | undefined;
let latest: ReturnType<typeof useRunActionDiscovery>;
let mounted: ReturnType<typeof createRoot> | undefined;
let host: HTMLDivElement;
let originalAct: boolean | undefined;
let originalResizeObserver: PropertyDescriptor | undefined;
const resizeObservers = new Set<ControlledResizeObserver>();
class ControlledResizeObserver {
  // These tests never resize the menu. Observe its cleanup without real layout
  // notifications or introducing a timer into the action activation sequence.
  constructor(_callback: ResizeObserverCallback) {
    resizeObservers.add(this);
  }
  observe(_element: Element) {}
  unobserve(_element: Element) {}
  disconnect() {
    resizeObservers.delete(this);
  }
}
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
function summary(
  id = pluginId,
  overrides: Partial<DeclarativePluginSummary> = {},
): DeclarativePluginSummary {
  return {
    pluginId: id,
    displayName: id,
    version: "1",
    apiVersion: 3,
    source: "installed",
    status: "accepted",
    enabled: true,
    languages: [{ id: "php", displayName: "PHP", fileExtensions: ["php"], fileNames: [] }],
    declaredSettings: [],
    declaresTests: true,
    primaryLanguageId: "php",
    rejection: null,
    ...overrides,
  };
}
function Harness({ path, workspace = scope }: { path?: string; workspace?: typeof scope }) {
  latest = useRunActionDiscovery(workspace.workspaceId, workspace.root, path, false);
  return (
    <div>
      {latest.declarativeActions.map((action) => (
        <button key={action.id}>{action.name}</button>
      ))}
    </div>
  );
}
beforeEach(() => {
  originalResizeObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    writable: true,
    value: ControlledResizeObserver,
  });
  originalAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.activateWorkspace(
    { id: scope.workspaceId, name: "Fixture", path: scope.root },
    "ready",
  );
  useSettingsStore.setState((state) => ({
    settings: { ...state.settings, displayLanguage: "en-US" },
  }));
  useExtensionStore.setState({ availableExtensions: new Map() });
  catalog = [summary()];
  calls = [];
  intercept = undefined;
  setPluginActive(pluginId, true);
  spyOn(projectDiscovery, "discoverProjectRunActions").mockResolvedValue([]);
  spyOn(uiExtensionHost, "discoverRunActions").mockResolvedValue([]);
  spyOn(native, "invoke").mockImplementation(
    async <T,>(command: string, args?: Parameters<typeof native.invoke>[1]): Promise<T> => {
      const input = (args ?? {}) as Record<string, unknown>;
      calls.push({ command, args: input });
      const delayed = intercept?.(command, input);
      if (delayed) return (await delayed) as T;
      if (command === "declarative_plugins_execution_context") return undefined as T;
      if (command === "declarative_plugins_state") return catalog as T;
      if (command === "declarative_plugins_manifest")
        return {
          executionProviders: [{ languageID: "php", run: {}, test: { frameworkID: "phpunit" } }],
        } as T;
      if (command === "declarative_plugins_language_owner")
        return { pluginId, languageId: "php", displayName: "PHP" } as T;
      if (command === "declarative_plugins_discover_tests")
        return {
          identity: "trusted-native",
          items: [
            { id: "php:workspace", kind: "workspace", label: "All PHP Tests" },
            { id: "php:workspace", kind: "workspace", label: "Duplicate" },
            {
              id: "php:file:tests/ItemTest.php",
              kind: "file",
              label: "tests/ItemTest.php",
              relativeFilePath: "tests/ItemTest.php",
            },
            {
              id: "php:file:sibling/Test.php",
              kind: "file",
              label: "sibling/Test.php",
              relativeFilePath: "sibling/Test.php",
            },
          ],
        } as T;
      throw new Error(`unexpected native command: ${command}`);
    },
  );
  host = document.createElement("div");
  document.body.append(host);
  mounted = createRoot(host);
});
afterEach(async () => {
  await act(async () => mounted?.unmount());
  mounted = undefined;
  host.remove();
  const observersRemaining = resizeObservers.size;
  resizeObservers.clear();
  if (originalResizeObserver)
    Object.defineProperty(globalThis, "ResizeObserver", originalResizeObserver);
  else Reflect.deleteProperty(globalThis, "ResizeObserver");
  extensionRegistry.unregisterExtension(workerId);
  setPluginActive(pluginId, false);
  setPluginActive(otherFrameworkPluginId, false);
  workspaceRuntimeRegistry.resetForTests();
  (await import("bun:test")).mock.restore();
  environment.IS_REACT_ACT_ENVIRONMENT = originalAct;
  expect(observersRemaining).toBe(0);
});

test("real hook discovers accepted workspace tests with no editor and no native file-owner query", async () => {
  catalog.push(
    summary("io.example.disabled", { enabled: false }),
    summary("io.example.rejected", { status: "rejected" }),
  );
  await act(async () => mounted!.render(<Harness />));
  expect(latest.declarativeActions).toHaveLength(1);
  expect(latest.declarativeActions[0]?.declarativeTestScope).toEqual({ kind: "workspace" });
  expect(
    calls
      .filter((call) => call.command === "declarative_plugins_discover_tests")
      .map((call) => call.args.pluginId),
  ).toEqual([pluginId]);
  expect(calls.some((call) => call.command === "declarative_plugins_language_owner")).toBe(false);
  expect(
    calls.find((call) => call.command === "declarative_plugins_discover_tests")?.args.context,
  ).toMatchObject({ workspaceId: scope.workspaceId, workspacePath: scope.root });
  expect(latest.discoveryError).toBeNull();
}, 3000);

test("real hook keeps two accepted test frameworks for the same language workspace", async () => {
  catalog.push(summary(otherFrameworkPluginId));
  setPluginActive(otherFrameworkPluginId, true);
  intercept = (command, args) => {
    if (command === "declarative_plugins_manifest" && args.pluginId === otherFrameworkPluginId)
      return Promise.resolve({
        executionProviders: [{ languageID: "php", test: { frameworkID: "pest" } }],
      });
  };
  await act(async () => mounted!.render(<Harness />));
  expect(
    latest.declarativeActions.map((action) => [
      action.declarativeOwner?.pluginId,
      action.testTarget?.frameworkId,
    ]),
  ).toEqual([
    [pluginId, "phpunit"],
    [otherFrameworkPluginId, "pest"],
  ]);
  expect(latest.declarativeActions.map((action) => action.declarativeTestScope)).toEqual([
    { kind: "workspace" },
    { kind: "workspace" },
  ]);
}, 3000);

test("real hook retains only the current file scope and stable workspace action across editor close", async () => {
  await act(async () => mounted!.render(<Harness path="C:/fixture/tests/ItemTest.php" />));
  const scopes = latest.declarativeActions
    .filter((action) => action.declarativeTest)
    .map((action) => action.declarativeTestScope);
  expect(scopes).toEqual([
    { kind: "workspace" },
    { kind: "file", relativeFilePath: "tests/ItemTest.php" },
  ]);
  await act(async () => mounted!.render(<Harness />));
  expect(latest.declarativeActions.map((action) => action.declarativeTestScope)).toEqual([
    { kind: "workspace" },
  ]);
}, 3000);

test("an external read-only editor cannot hide the independent workspace test action", async () => {
  await act(async () => mounted!.render(<Harness path="C:/external/ItemTest.php" />));
  expect(latest.declarativeActions.map((action) => action.declarativeTestScope)).toEqual([
    { kind: "workspace" },
  ]);
  expect(calls.some((call) => call.command === "declarative_plugins_language_owner")).toBe(false);
}, 3000);

test("real Worker language ownership wins without an editor and its duplicate action has one entry", async () => {
  extensionRegistry.registerExtension({
    id: workerId,
    name: "Worker",
    version: "1",
    languages: [{ id: "php", extensions: [".php"] }],
    runActions: { manifestFiles: ["composer.json"], executables: ["php"] },
  } as Parameters<typeof extensionRegistry.registerExtension>[0]);
  useExtensionStore.setState({
    availableExtensions: new Map([
      [
        workerId,
        {
          isInstalled: true,
          isEnabled: true,
          manifest: extensionRegistry.getExtension(workerId)!.manifest,
        } as never,
      ],
    ]),
  });
  const action: RunActionItem = {
    id: "worker:tests",
    name: "Worker tests",
    source: "extension",
    sourceLabel: "Worker",
    extensionId: workerId,
  };
  spyOn(uiExtensionHost, "discoverRunActions").mockResolvedValue([action, action]);
  await act(async () => mounted!.render(<Harness />));
  expect(latest.declarativeActions).toEqual([]);
  expect(latest.projectActions.map((entry) => entry.id)).toEqual([action.id]);
  expect(calls.some((call) => call.command === "declarative_plugins_discover_tests")).toBe(false);
}, 3000);

test("a late native discovery from another workspace never appears in the real hook", async () => {
  const entered = deferred<void>();
  const answer = deferred<unknown>();
  intercept = (command, args) => {
    if (
      command === "declarative_plugins_discover_tests" &&
      (args.context as { workspaceId: string }).workspaceId === scope.workspaceId
    ) {
      entered.resolve();
      return answer.promise;
    }
  };
  try {
    await act(async () => mounted!.render(<Harness />));
    await entered.promise;
    expect(latest.isDiscovering).toBe(true);
    const other = { workspaceId: "r7-other", root: "C:/other" };
    await act(async () => {
      workspaceRuntimeRegistry.activateWorkspace(
        { id: other.workspaceId, name: "Other", path: other.root },
        "ready",
      );
      catalog = [];
      mounted!.render(<Harness workspace={other} />);
    });
    await act(async () =>
      answer.resolve({ identity: "old", items: [{ id: "old", kind: "workspace", label: "Old" }] }),
    );
    expect(latest.declarativeActions).toEqual([]);
    expect(host.textContent).not.toContain("Old");
  } finally {
    await act(async () => answer.resolve({ identity: "old", items: [] }));
  }
}, 3000);

test("existing typed build/language scopes take precedence while opaque scripts remain separate", async () => {
  const existing: RunActionItem = {
    id: "build:workspace-tests",
    name: "Build tests",
    source: "cargo",
    sourceLabel: "Build",
    testTarget: { languageId: "php", frameworkId: "phpunit", scope: { kind: "workspace" } },
  };
  const opaque: RunActionItem = {
    id: "custom-script",
    name: "All PHP Tests",
    command: "custom-test",
    source: "package",
    sourceLabel: "Scripts",
  };
  spyOn(projectDiscovery, "discoverProjectRunActions").mockResolvedValue([
    existing,
    existing,
    opaque,
  ]);
  await act(async () => mounted!.render(<Harness path="C:/fixture/tests/ItemTest.php" />));
  expect(latest.projectActions.map((action) => action.id)).toEqual([existing.id, opaque.id]);
  expect(
    latest.declarativeActions
      .filter((action) => action.declarativeTest)
      .map((action) => action.declarativeTestScope),
  ).toEqual([{ kind: "file", relativeFilePath: "tests/ItemTest.php" }]);
}, 3000);

test("production toolbar keeps its capability gate closed", async () => {
  expect(backend.backendCapabilities.runActions).toBe(false);
  await act(async () =>
    mounted!.render(
      <LocaleProvider language="en-US">
        <RunActionsButton />
      </LocaleProvider>,
    ),
  );
  expect(host.querySelector<HTMLButtonElement>("button[aria-haspopup='menu']")?.disabled).toBe(
    true,
  );
  expect(calls.some((call) => call.command === "declarative_plugins_discover_tests")).toBe(false);
}, 3000);

test("real toolbar and menu route one workspace click without an editor and suppress repeated activation", async () => {
  // Availability is a view fixture only. The compiled flag above and native
  // executionProviders acceptance remain closed; no product process is run.
  const available = backend.isBackendCapabilityAvailable;
  spyOn(backend, "isBackendCapabilityAvailable").mockImplementation(
    (capability) => capability === "runActions" || available(capability),
  );
  useFileSystemStore.getStore(scope.workspaceId).setState({ rootFolderPath: scope.root });
  useBufferStore.getStore(scope.workspaceId).setState({ buffers: [], activeBufferId: null });
  useWorkspaceTabsStore.setState({
    projectTabs: [
      { id: scope.workspaceId, name: "Fixture", path: scope.root, isActive: true, lastOpened: 1 },
    ],
  });
  const released = deferred<void>();
  const launched = spyOn(execution, "runDeclarativeAction").mockImplementation(
    async () => released.promise,
  );
  try {
    await act(async () =>
      mounted!.render(
        <LocaleProvider language="en-US">
          <RunActionsButton />
        </LocaleProvider>,
      ),
    );
    const trigger = host.querySelector<HTMLButtonElement>("button[aria-haspopup='menu']")!;
    await act(async () => trigger.click());
    const action = [...document.querySelectorAll<HTMLButtonElement>("button")].find((button) =>
      button.textContent?.includes("Test All PHP Tests"),
    );
    expect(action).toBeDefined();
    await act(async () => {
      action!.click();
      action!.click();
    });
    expect(launched).toHaveBeenCalledTimes(1);
    expect(launched.mock.calls[0]?.slice(1)).toEqual([scope.workspaceId, scope.root, undefined]);
    expect(launched.mock.calls[0]?.[0].declarativeTestScope).toEqual({ kind: "workspace" });
  } finally {
    released.resolve();
    await act(async () => released.promise);
    await act(async () => useWorkspaceTabsStore.setState({ projectTabs: [] }));
  }
}, 3000);
