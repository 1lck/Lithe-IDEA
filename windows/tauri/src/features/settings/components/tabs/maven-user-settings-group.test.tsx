import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { MavenUserSettings } from "@/features/maven/types/maven.types";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  MavenUserSettingsGroup,
  type MavenUserSettingsDependencies,
} from "./maven-user-settings-group";

const MISSING: MavenUserSettings = {
  path: "C:/Users/fixture/.m2/settings.xml",
  status: "missing",
  localRepository: null,
  defaultLocalRepository: "C:/Users/fixture/.m2/repository",
  revision: null,
};

// React DOM must detect the DOM before initializing its input event handling.
const restoreDom = installHappyDom();
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
environment.IS_REACT_ACT_ENVIRONMENT = true;
afterAll(() => {
  if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
  else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  restoreDom();
});
const { createRoot } = await import("react-dom/client");

async function render(dependencies: MavenUserSettingsDependencies, onSaved?: () => void) {
  const container = document.createElement("div");
  document.body.append(container);
  const root: Root = createRoot(container);
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <MavenUserSettingsGroup projectOpen dependencies={dependencies} onSaved={onSaved} />
      </LocaleProvider>,
    );
  });
  const input = () => container.querySelector("input")!;
  const saveButton = () =>
    [...container.querySelectorAll("button")].find(
      (button) => button.textContent === "Save to settings.xml",
    )!;
  const type = async (value: string) => {
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(input(), value);
      input().dispatchEvent(new Event("input", { bubbles: true }));
    });
  };
  const cleanup = async () => {
    await act(async () => root.unmount());
    container.remove();
  };
  return { container, input, saveButton, type, cleanup };
}

test("Maven's default is shown as the value and opening the page writes nothing", async () => {
  const writes: unknown[] = [];
  const view = await render({
    read: async () => MISSING,
    write: async (...args) => {
      writes.push(args);
      return MISSING;
    },
    browse: async () => null,
  });
  try {
    expect(view.input().value).toBe(MISSING.defaultLocalRepository);
    expect(view.container.textContent).toContain("Maven default");
    expect(view.container.textContent).toContain("not created yet");
    // The unchanged default is not an explicit setting, so there is nothing to save.
    expect(view.saveButton().disabled).toBe(true);
    expect(writes).toEqual([]);
  } finally {
    await view.cleanup();
  }
});

test("saving writes against the read revision and shows the value read back", async () => {
  const writes: Array<[string, string | null]> = [];
  let saved = 0;
  const view = await render(
    {
      read: async () => ({ ...MISSING, status: "readable", revision: "r1" }),
      write: async (localRepository, expectedRevision) => {
        writes.push([localRepository, expectedRevision]);
        return { ...MISSING, status: "readable", localRepository, revision: "r2" };
      },
      browse: async () => null,
    },
    () => saved++,
  );
  try {
    await view.type("  D:/maven/repository ");
    expect(view.saveButton().disabled).toBe(false);
    await act(async () => view.saveButton().click());
    expect(writes).toEqual([["D:/maven/repository", "r1"]]);
    expect(saved).toBe(1);
    expect(view.input().value).toBe("D:/maven/repository");
    expect(view.saveButton().disabled).toBe(true);
    expect(view.container.textContent).toContain("Reload the Maven project");
  } finally {
    await view.cleanup();
  }
});

test("a conflicting write keeps the draft until the file is read again", async () => {
  let reads = 0;
  const view = await render({
    read: async () => ({
      ...MISSING,
      status: "readable",
      localRepository: reads++ === 0 ? "D:/old" : "D:/external",
      revision: `r${reads}`,
    }),
    write: async () => {
      throw new Error("mavenUserSettingsChanged: C:/Users/fixture/.m2/settings.xml changed");
    },
    browse: async () => null,
  });
  try {
    await view.type("D:/mine");
    await act(async () => view.saveButton().click());
    expect(view.container.querySelector('[role="alert"]')?.textContent).toContain(
      "changed after it was read",
    );
    expect(view.input().value).toBe("D:/mine");

    const reload = [...view.container.querySelectorAll("button")].find(
      (button) => button.textContent === "Reload",
    )!;
    await act(async () => reload.click());
    expect(view.input().value).toBe("D:/mine");
    expect(view.container.querySelector('[role="alert"]')).toBeNull();
    expect(view.saveButton().disabled).toBe(false);
  } finally {
    await view.cleanup();
  }
});

test("an invalid settings file is not editable", async () => {
  const view = await render({
    read: async () => ({ ...MISSING, status: "invalid", revision: "r1" }),
    write: async () => MISSING,
    browse: async () => null,
  });
  try {
    expect(view.input().disabled).toBe(true);
    expect(view.saveButton().disabled).toBe(true);
    expect(view.container.textContent).toContain("Lithe will not change it");
  } finally {
    await view.cleanup();
  }
});
