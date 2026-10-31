import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import type { GeneratorEntry } from "./generator-form-session";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
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
async function mount(enabled = true, failEnable = false, entry = fixture(enabled)) {
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
          <Wizard parent="fixture" onBack={() => {}} onClose={() => {}} />
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
  return {
    host,
    calls,
    close: async () => {
      try {
        await act(async () => root.unmount());
      } finally {
        host.remove();
        invoke.mockRestore();
        environment.IS_REACT_ACT_ENVIRONMENT = previous;
      }
    },
  };
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
    expect(document.activeElement).toBe(options[1]);
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
