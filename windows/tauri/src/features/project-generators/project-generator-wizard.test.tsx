import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Action } from "sonner";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { createProjectTabId } from "@/features/window/utils/project-tab-path";
import type { GeneratorEntry } from "./generator-form-session";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { useFileSystemStore } = await import("@/features/file-system/stores/file-system.store");
const { useUIState } = await import("@/features/window/stores/ui-state.store");
const { toast } = await import("sonner");
const { default: Wizard } = await import("./project-generator-wizard");

function fixture(enabled = true): GeneratorEntry {
  return {
    pluginID: "fixture.generator",
    pluginName: "Fixture Generator",
    pluginEnabled: enabled,
    packageIdentity: "bytes-a",
    canEnable: true,
    generator: {
      id: "app",
      displayName: "Fixture App",
      section: "project",
      fields: [
        {
          id: "build",
          type: "enum",
          title: "Build system",
          presentation: "segmented",
          options: [
            { value: "none", title: "None" },
            { value: "maven", title: "Maven" },
          ],
        },
        { id: "group", type: "text", title: "Group", advanced: true },
      ],
    },
    requirements: [
      {
        languageID: "java",
        providers: [
          {
            pluginID: "fixture.generator",
            pluginName: "Fixture Generator",
            enabled,
            canEnable: true,
          },
        ],
      },
      { buildSystemID: "maven", providers: [] },
    ],
  };
}
async function settle() {
  for (let index = 0; index < 5; ++index)
    await act(async () => {
      await Promise.resolve();
    });
}
function inputValue(input: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}
const button = (host: HTMLElement, label: string) => {
  const result = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent?.trim() === label,
  );
  if (!result) throw new Error(`Missing button ${label}`);
  return result;
};
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
const reviewedRuntime = {
  field: "jdk",
  runtime: "java",
  home: "C:/fixture/jdk",
  version: "21.0.8",
};
async function mount(
  enabled = true,
  failEnable = false,
  entry = fixture(enabled),
  generation?: { run(): Promise<{ root: string; openFiles: string[] }>; closed(): void },
) {
  const calls: string[] = [];
  let current = entry;
  const invoke = spyOn(native, "invoke").mockImplementation(
    async <T,>(command: string, input?: Parameters<typeof native.invoke>[1]): Promise<T> => {
      const args = input as Record<string, unknown> | undefined;
      calls.push(command);
      if (command === "declarative_plugins_generator_catalog")
        return { generators: [current] } as T;
      if (command === "declarative_plugins_generator_form") {
        const form = args!.form as { projectName: string; values: Record<string, unknown> };
        return {
          packageIdentity: current.packageIdentity,
          valid: !!form.projectName,
          projectName: {},
          activeRequirements: form.values.build === "maven" ? [0, 1] : [0],
          fields: current.generator.fields?.length
            ? [
                { id: "build", visible: true, value: form.values.build ?? "none" },
                {
                  id: "group",
                  visible: form.values.build === "maven",
                  value: form.values.group ?? "org.example",
                },
              ]
            : [],
        } as T;
      }
      if (command === "declarative_plugins_set_enabled") {
        expect(args).toEqual({ pluginId: "fixture.generator", enabled: true });
        if (failEnable) throw new Error("fixture trust rejection");
        current = fixture(true);
        return undefined as T;
      }
      if (command === "declarative_marketplace_list" || command === "declarative_plugins_state")
        return [] as T;
      if (command === "declarative_plugins_generator_cancel") return undefined as T;
      if (command === "declarative_plugins_generator_prepare")
        return {
          id: "review",
          destination: "C:/created",
          plan: { steps: [], usesNetwork: false, runtimes: [reviewedRuntime] },
          programs: [],
        } as T;
      if (command === "declarative_plugins_generator_generate" && generation)
        return (await generation.run()) as T;
      throw new Error(`Unexpected command ${command}`);
    },
  );
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previous = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  try {
    await act(async () => {
      root.render(
        <LocaleProvider language="en-US">
          <Wizard parent="fixture" onBack={() => {}} onClose={() => generation?.closed()} />
        </LocaleProvider>,
      );
    });
    await settle();
  } catch (error) {
    await act(async () => root.unmount());
    host.remove();
    invoke.mockRestore();
    environment.IS_REACT_ACT_ENVIRONMENT = previous;
    throw error;
  }
  let mounted = true;
  const unmount = async () => {
    if (!mounted) return;
    mounted = false;
    await act(async () => root.unmount());
  };
  return {
    host,
    calls,
    unmount,
    close: async () => {
      try {
        await unmount();
      } finally {
        host.remove();
        invoke.mockRestore();
        environment.IS_REACT_ACT_ENVIRONMENT = previous;
      }
    },
  };
}

async function review(view: Awaited<ReturnType<typeof mount>>) {
  await act(async () => button(view.host, "Fixture App · Fixture Generator").click());
  await settle();
  await act(async () =>
    inputValue(view.host.querySelector<HTMLInputElement>("#generator-name")!, "Created"),
  );
  await settle();
  await act(async () => button(view.host, "Review creation").click());
  await settle();
}

test("creation review shows the native JDK home and exact version", async () => {
  const view = await mount();
  try {
    await review(view);
    const rendered = JSON.parse(view.host.querySelector("details pre")!.textContent!);
    expect(rendered.runtimes).toEqual([reviewedRuntime]);
  } finally {
    await view.close();
  }
}, 2000);

test("generated files stay with B and its late handoff keeps A's reopened picker visible", async () => {
  const previous = workspaceRuntimeRegistry.getActiveWorkspace();
  const source = { id: "generator-handoff-a", name: "A", path: "C:/source-a" };
  const project = { root: "C:/created-b", openFiles: ["C:/created-b/main.mjs"] };
  const target = { id: createProjectTabId(project.root), name: "B", path: project.root };
  const opened = deferred<boolean>();
  const events: string[] = [];
  workspaceRuntimeRegistry.activateWorkspace(source, "ready");
  workspaceRuntimeRegistry.ensureWorkspace(target, "ready");
  const sourceStore = useFileSystemStore.getStore(source.id);
  const targetStore = useFileSystemStore.getStore(target.id);
  const sourceUI = useUIState.getStore(source.id);
  sourceUI.getState().setIsProjectPickerVisible(true, "new-project");
  sourceStore.setState({ rootFolderPath: source.path });
  targetStore.setState({ rootFolderPath: target.path });
  const open = spyOn(sourceStore.getState(), "handleOpenFolderByPath").mockImplementation(
    async () => {
      events.push("B opening");
      workspaceRuntimeRegistry.activateWorkspace(target, "ready");
      return opened.promise;
    },
  );
  const openA = spyOn(sourceStore.getState(), "handleFileOpen").mockImplementation(async () => {
    events.push("A file");
  });
  const openB = spyOn(targetStore.getState(), "handleFileOpen").mockImplementation(async () => {
    events.push("B file");
  });
  let closeView = async () => {};
  try {
    const view = await mount(true, false, fixture(), {
      run: async () => project,
      closed: () => {
        events.push("closed");
        sourceUI.getState().setIsProjectPickerVisible(false);
      },
    });
    closeView = view.close;
    await review(view);
    await act(async () => button(view.host, "Create project").click());
    await settle();
    expect(events[0]).toBe("B opening");
    // Activating B closes the source workspace's picker in the product.
    await view.unmount();
    workspaceRuntimeRegistry.activateWorkspace(source, "ready");
    // The source workspace now owns a new picker incarnation while the old
    // handoff is still pending. Its visibility must survive the old callback.
    sourceUI.getState().setIsProjectPickerVisible(true, "new-project");
    opened.resolve(true);
    await settle();
    expect(openA).not.toHaveBeenCalled();
    expect(openB).toHaveBeenCalledWith(project.openFiles[0], false);
    expect(workspaceRuntimeRegistry.getActiveWorkspaceId()).toBe(source.id);
    expect(sourceUI.getState().isProjectPickerVisible).toBe(true);
    expect(events).toEqual(["B opening", "closed", "B file"]);
  } finally {
    opened.resolve(false);
    await settle();
    await closeView();
    open.mockRestore();
    openA.mockRestore();
    openB.mockRestore();
    if (previous) workspaceRuntimeRegistry.activateWorkspace(previous.descriptor, previous.status);
    workspaceRuntimeRegistry.removeWorkspace(source.id);
    workspaceRuntimeRegistry.removeWorkspace(target.id);
  }
}, 2000);

for (const failure of ["rejected", "thrown"] as const) {
  test(`a ${failure} B open after source close offers an explicit retry without generating again`, async () => {
    const previous = workspaceRuntimeRegistry.getActiveWorkspace();
    const source = { id: "generator-retry-a", name: "A", path: "C:/retry-a" };
    const project = { root: "C:/retry-b", openFiles: ["C:/retry-b/main.mjs"] };
    const target = { id: createProjectTabId(project.root), name: "B", path: project.root };
    const opened = deferred<boolean>();
    workspaceRuntimeRegistry.activateWorkspace(source, "ready");
    workspaceRuntimeRegistry.ensureWorkspace(target, "ready");
    const sourceStore = useFileSystemStore.getStore(source.id);
    const targetStore = useFileSystemStore.getStore(target.id);
    const sourceUI = useUIState.getStore(source.id);
    sourceUI.getState().setIsProjectPickerVisible(true, "new-project");
    const closeEvents: string[] = [];
    let attempts = 0;
    const open = spyOn(sourceStore.getState(), "handleOpenFolderByPath").mockImplementation(
      async () => {
        workspaceRuntimeRegistry.activateWorkspace(target, "ready");
        if (++attempts > 1) return true;
        await opened.promise;
        // The real workspace opener rolls back to A after initialization fails.
        workspaceRuntimeRegistry.activateWorkspace(source, "ready");
        if (failure === "thrown") throw new Error("fixture workspace initialization failure");
        return false;
      },
    );
    const openB = spyOn(targetStore.getState(), "handleFileOpen").mockResolvedValue(undefined);
    const feedback = spyOn(toast, "error").mockReturnValue("generator-retry");
    let closeView = async () => {};
    try {
      const view = await mount(true, false, fixture(), {
        run: async () => project,
        closed: () => {
          closeEvents.push("closed");
          sourceUI.getState().setIsProjectPickerVisible(false);
        },
      });
      closeView = view.close;
      await review(view);
      await act(async () => button(view.host, "Create project").click());
      await settle();
      await view.unmount();
      opened.resolve(false);
      await settle();
      expect(workspaceRuntimeRegistry.getActiveWorkspaceId()).toBe(source.id);
      expect(feedback).toHaveBeenCalledWith(
        "The project was created but Lithe could not open it.",
        expect.objectContaining({
          action: expect.objectContaining({ label: "Open created project" }),
        }),
      );
      const retry = feedback.mock.calls[0]![1]!.action as Action;
      sourceUI.getState().setIsProjectPickerVisible(true, "new-project");
      await act(async () => retry.onClick({} as Parameters<Action["onClick"]>[0]));
      await settle();
      expect(open).toHaveBeenCalledTimes(2);
      expect(openB).toHaveBeenCalledWith(project.openFiles[0], false);
      expect(
        view.calls.filter((name) => name === "declarative_plugins_generator_generate"),
      ).toHaveLength(1);
      expect(closeEvents).toEqual(["closed"]);
      expect(sourceUI.getState().isProjectPickerVisible).toBe(true);
      expect(workspaceRuntimeRegistry.getActiveWorkspaceId()).toBe(target.id);
    } finally {
      opened.resolve(false);
      await settle();
      await closeView();
      open.mockRestore();
      openB.mockRestore();
      feedback.mockRestore();
      if (previous)
        workspaceRuntimeRegistry.activateWorkspace(previous.descriptor, previous.status);
      workspaceRuntimeRegistry.removeWorkspace(source.id);
      workspaceRuntimeRegistry.removeWorkspace(target.id);
    }
  }, 2000);
}

for (const interruption of ["switch", "close"] as const) {
  test(`generation completing after a workspace ${interruption} cannot open its old result`, async () => {
    const previous = workspaceRuntimeRegistry.getActiveWorkspace();
    const source = { id: "generator-late-a", name: "A" };
    const next = { id: "generator-late-b", name: "B" };
    const generated = deferred<{ root: string; openFiles: string[] }>();
    workspaceRuntimeRegistry.activateWorkspace(source, "ready");
    const openA = spyOn(
      useFileSystemStore.getStore(source.id).getState(),
      "handleOpenFolderByPath",
    ).mockResolvedValue(false);
    const openB = spyOn(
      useFileSystemStore.getStore(next.id).getState(),
      "handleOpenFolderByPath",
    ).mockResolvedValue(false);
    const closed: string[] = [];
    let closeView = async () => {};
    try {
      const view = await mount(true, false, fixture(), {
        run: () => generated.promise,
        closed: () => closed.push("closed"),
      });
      closeView = view.close;
      await review(view);
      await act(async () => button(view.host, "Create project").click());
      if (interruption === "switch") {
        await act(async () => workspaceRuntimeRegistry.activateWorkspace(next, "ready"));
      } else {
        await view.unmount();
      }
      generated.resolve({ root: "C:/late-created", openFiles: ["C:/late-created/main.mjs"] });
      await settle();
      expect(openA).not.toHaveBeenCalled();
      expect(openB).not.toHaveBeenCalled();
      expect(closed).toEqual([]);
      expect(view.calls).toContain("declarative_plugins_generator_cancel");
    } finally {
      generated.resolve({ root: "C:/late-created", openFiles: [] });
      await settle();
      await closeView();
      openA.mockRestore();
      openB.mockRestore();
      if (previous)
        workspaceRuntimeRegistry.activateWorkspace(previous.descriptor, previous.status);
      workspaceRuntimeRegistry.removeWorkspace(source.id);
      workspaceRuntimeRegistry.removeWorkspace(next.id);
    }
  }, 2000);
}

for (const representation of ["omitted", "empty"] as const) {
  test(`fieldless catalog with ${representation} fields keeps the wizard usable`, async () => {
    const entry = fixture();
    entry.generator.fields = [];
    entry.requirements = [];
    if (representation === "omitted") Reflect.deleteProperty(entry.generator, "fields");
    const view = await mount(true, false, entry);
    try {
      await act(async () => button(view.host, "Fixture App · Fixture Generator").click());
      await settle();
      const name = view.host.querySelector<HTMLInputElement>("#generator-name")!;
      expect(name).not.toBeNull();
      expect(button(view.host, "Review creation").disabled).toBe(true);
      await act(async () => inputValue(name, "Archive Project"));
      await settle();
      expect(name.value).toBe("Archive Project");
      expect(button(view.host, "Review creation").disabled).toBe(false);
      expect(view.host.querySelector('[role="alert"]')).toBeNull();
    } finally {
      await view.close();
    }
  }, 2000);
}

test("disabled entry is inspectable and creation waits for explicit enable and native re-read", async () => {
  const view = await mount(false);
  try {
    const entry = [...view.host.querySelectorAll<HTMLButtonElement>("button")].find((button) =>
      button.textContent?.includes("Fixture App"),
    )!;
    expect(entry.disabled).toBe(false);
    await act(async () => entry.click());
    await settle();
    await act(async () =>
      inputValue(view.host.querySelector<HTMLInputElement>("#generator-name")!, "Draft"),
    );
    await settle();
    expect(button(view.host, "Review creation").disabled).toBe(true);
    await act(async () => button(view.host, "Enable Fixture Generator").click());
    await settle();
    expect(view.host.querySelector<HTMLInputElement>("#generator-name")!.value).toBe("Draft");
    expect(button(view.host, "Review creation").disabled).toBe(false);
    expect(
      view.calls.filter((name) => name === "declarative_plugins_generator_catalog"),
    ).toHaveLength(2);
    expect(
      view.calls.some(
        (name) =>
          name.includes("confirm") || name.includes("prepare") || name.includes("start_execution"),
      ),
    ).toBe(false);
  } finally {
    await view.close();
  }
}, 2000);

test("enable rejection leaves the disabled generator visible and create disabled", async () => {
  const view = await mount(false, true);
  try {
    const entry = [...view.host.querySelectorAll<HTMLButtonElement>("button")].find((button) =>
      button.textContent?.includes("Fixture App"),
    )!;
    await act(async () => entry.click());
    await settle();
    await act(async () => button(view.host, "Enable Fixture Generator").click());
    await settle();
    expect(view.host.querySelector('[role="alert"]')).not.toBeNull();
    expect(button(view.host, "Review creation").disabled).toBe(true);
    expect(button(view.host, "Enable Fixture Generator")).toBeDefined();
  } finally {
    await view.close();
  }
}, 2000);

test("segmented keyboard focus, conditional advanced draft and marketplace prefilled query use shared controls", async () => {
  const view = await mount();
  try {
    await act(async () => button(view.host, "Fixture App · Fixture Generator").click());
    await settle();
    const group = view.host.querySelector<HTMLElement>('[data-slot="toggle-group"]')!;
    expect(group.getAttribute("aria-label")).toBe("Build system");
    const options = group.querySelectorAll<HTMLButtonElement>("button");
    await act(async () => {
      options[0].focus();
      options[0].dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    });
    expect(document.activeElement === options[1], "Maven option owns keyboard focus").toBe(true);
    await act(async () => button(view.host, "Maven").click());
    await settle();
    expect(view.host.querySelector("#generator-field-group")).toBeNull();
    const advanced = [...view.host.querySelectorAll("label")]
      .find((label) => label.textContent?.includes("Advanced fields"))!
      .querySelector<HTMLInputElement>("input")!;
    await act(async () => advanced.click());
    await settle();
    await act(async () =>
      inputValue(
        view.host.querySelector<HTMLInputElement>("#generator-field-group")!,
        "keep.group",
      ),
    );
    await settle();
    await act(async () => button(view.host, "None").click());
    await settle();
    expect(view.host.querySelector("#generator-field-group")).toBeNull();
    await act(async () => button(view.host, "Maven").click());
    await settle();
    expect(view.host.querySelector<HTMLInputElement>("#generator-field-group")!.value).toBe(
      "keep.group",
    );
    await act(async () => button(view.host, "Find maven in plugin marketplace").click());
    await settle();
    expect(
      view.host.querySelector<HTMLInputElement>('[data-testid="marketplace-search-input"]')!.value,
    ).toBe("maven");
    expect(view.calls.some((name) => name.includes("confirm") || name.includes("prepare"))).toBe(
      false,
    );
  } finally {
    await view.close();
  }
}, 2000);
