import { afterAll, afterEach, expect, mock, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type {
  DeclarativePluginSetting,
  DeclarativeSettingSnapshot,
} from "./declarative-plugin-launch";
import { pluginSettingsReloads } from "./declarative-plugin-reload";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const declarations: DeclarativePluginSetting[] = [
  {
    id: "reload",
    title: "Reload option",
    type: "text",
    default: "default",
    scope: "project",
    effect: "reload",
    section: "Models",
  },
  {
    id: "global",
    title: "Global only",
    type: "boolean",
    default: false,
    scope: "global",
    effect: "nextRun",
  },
];
function snapshot(): DeclarativeSettingSnapshot {
  return {
    manifest: {},
    settings: declarations,
    settingActions: [],
    globalValues: {},
    projectValues: {},
    resolvedGlobal: declarations.map((item) => ({
      id: item.id,
      value: item.default,
      source: "default",
    })),
    resolvedProject: [
      { id: "reload", value: "inherited-from-core", source: "global" },
      { id: "global", value: false, source: "default" },
    ],
    globalPath: "/fixture/preferences.json",
    projectPath: "/fixture/project/.lithe/plugin-settings.json",
    identity: "baseline",
    packageIdentity: "approved",
    reloadContext: { workspaceId: "project-a", registration: 17, windowIncarnation: 1 },
  };
}
let current = snapshot();
const writes: any[][] = [];
let write = async (...args: any[]) => {
  writes.push(args);
  current = {
    ...current,
    identity: "saved",
    projectValues: args[4] === null ? {} : { reload: args[4] },
    resolvedProject: [
      args[4] === null
        ? snapshot().resolvedProject[0]!
        : { id: "reload", value: args[4], source: "project" },
      current.resolvedProject[1]!,
    ],
  };
  return current;
};
mock.module("./declarative-plugin-launch", () => ({
  loadDeclarativeSettingSnapshot: async () => current,
  storeDeclarativeSetting: (...args: any[]) => write(...args),
  declarativeWorkspaceConfiguration: async () => ({ status: "ok" }),
}));
mock.module("@/platform/lsp-core-adapter", () => ({
  pushDeclarativeWorkspaceConfiguration: async () => false,
}));
const { DeclarativePluginSettingsEditor } = await import("./declarative-plugin-settings-editor");
let root: Root | null = null;
let host: HTMLDivElement;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
afterEach(async () => {
  await act(async () => {
    root?.unmount();
  });
  host?.remove();
  root = null;
  workspaceRuntimeRegistry.resetForTests();
  for (const state of pluginSettingsReloads.states())
    pluginSettingsReloads.postpone(pluginSettingsReloads.key(state.receipt));
  writes.length = 0;
  current = snapshot();
  environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
});
async function mount() {
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "project-a", name: "Project", path: "/fixture/project" },
    "ready",
  );
  host = document.createElement("div");
  document.body.append(host);
  await act(async () => {
    root = createRoot(host);
    root.render(
      <LocaleProvider>
        <DeclarativePluginSettingsEditor
          pluginId="example.plugin"
          settings={declarations}
          workspacePath="/fixture/project"
          languageId={null}
        />
      </LocaleProvider>,
    );
  });
}
async function projectLayer() {
  await act(async () => {
    host
      .querySelector<HTMLButtonElement>("[role=combobox]")!
      .dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  });
  const options = document.querySelectorAll<HTMLElement>("[role=option]");
  expect(options).toHaveLength(2);
  await act(async () => {
    options[1]!.click();
  });
}
function input() {
  return host.querySelector<HTMLInputElement>('[aria-label="Reload option"]')!;
}
function save() {
  return host.querySelector<HTMLButtonElement>(
    '[aria-label="Reload option: Save"], [aria-label="Reload option: 保存"]',
  )!;
}
function edit(value: string) {
  const element = input();
  Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!.call(
    element,
    value,
  );
  element.dispatchEvent(new Event("input", { bubbles: true }));
}

test("the production form displays Core project inheritance, locks global-only rows and queues reload after explicit save", async () => {
  await mount();
  expect(writes).toEqual([]);
  await projectLayer();
  expect(input().value).toBe("inherited-from-core");
  expect(
    host.querySelector('[data-plugin-setting="global"] button')?.hasAttribute("disabled"),
  ).toBe(true);
  await act(async () => {
    edit("");
  });
  expect(save().disabled).toBe(false);
  expect(writes).toEqual([]);
  await act(async () => {
    save().click();
  });
  expect(writes).toEqual([
    ["example.plugin", "reload", "project", "/fixture/project", "", "baseline"],
  ]);
  expect(pluginSettingsReloads.states().map((state) => state.receipt)).toEqual([
    {
      pluginId: "example.plugin",
      workspacePath: "/fixture/project",
      expectedIdentity: "saved",
      expectedPackageIdentity: "approved",
      scope: "project",
      project: { workspaceId: "project-a", registration: 17, windowIncarnation: 1 },
    },
  ]);
  expect(input().value).toBe("");
}, 3000);

test("the production form retains a rejected draft and never queues reload on CAS conflict", async () => {
  await mount();
  await projectLayer();
  const original = write;
  write = async () => {
    throw new Error("plugin.settings.conflict");
  };
  try {
    await act(async () => {
      edit("draft");
    });
    await act(async () => {
      save().click();
    });
    expect(input().value).toBe("draft");
    expect(host.querySelector("[role=alert]")?.textContent).toContain("plugin.settings.conflict");
    expect(pluginSettingsReloads.states()).toEqual([]);
  } finally {
    write = original;
  }
}, 3000);

test("Cancel discards a draft and Inherit erases an explicit empty override through the same save flow", async () => {
  current.projectValues = { reload: "" };
  current.resolvedProject[0] = { id: "reload", value: "", source: "project" };
  await mount();
  await projectLayer();
  await act(async () => {
    edit("unsaved");
  });
  await act(async () => {
    host
      .querySelector<HTMLButtonElement>(
        '[aria-label="Reload option: Cancel"], [aria-label="Reload option: 取消"]',
      )!
      .click();
  });
  expect(input().value).toBe("");
  expect(writes).toEqual([]);
  const buttons = host.querySelectorAll<HTMLButtonElement>('[data-plugin-setting="reload"] button');
  const inherit = buttons[buttons.length - 1]!;
  await act(async () => {
    inherit.click();
  });
  expect(writes[0]?.[4]).toBeNull();
  expect(input().value).toBe("inherited-from-core");
  expect(pluginSettingsReloads.states()[0]?.receipt.scope).toBe("project");
}, 3000);

test("a saved reply after workspace replacement cannot queue reload or replace the form baseline", async () => {
  await mount();
  await projectLayer();
  let resolve!: (value: DeclarativeSettingSnapshot) => void;
  const gate = new Promise<DeclarativeSettingSnapshot>((done) => {
    resolve = done;
  });
  const original = write;
  write = () => gate;
  try {
    await act(async () => {
      edit("draft");
    });
    await act(async () => {
      save().click();
    });
    await act(async () => {
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "other", name: "Other", path: "/fixture/other" },
        "ready",
      );
      resolve({ ...current, identity: "late-save" });
    });
    expect(pluginSettingsReloads.states()).toEqual([]);
    expect(host.querySelector("[role=alert]")?.textContent).toContain("staleContext");
    expect(input().value).toBe("draft");
  } finally {
    resolve(current);
    write = original;
  }
}, 3000);
