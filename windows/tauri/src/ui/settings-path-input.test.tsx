import { afterAll, expect, test } from "bun:test";
import { act, useState, type ComponentProps } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

const restoreDom = installHappyDom();
afterAll(restoreDom);
// Load browser-dependent controls after installing DOM globals, including portal support.
const { default: SettingsPathInput } = await import("./settings-path-input");
const { createRoot } = await import("react-dom/client");

type PathInputProps = ComponentProps<typeof SettingsPathInput>;
type PathInputFixture = {
  input: HTMLInputElement;
  changes: string[];
  edit: (value: string) => Promise<void>;
  press: (key: string) => Promise<void>;
};

async function withPathInput(
  props: Pick<PathInputProps, "value" | "candidates">,
  verify: (fixture: PathInputFixture) => Promise<void>,
) {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const changes: string[] = [];
  const host = document.createElement("div");
  let root: Root | undefined;
  function ProjectPath() {
    const [value, setValue] = useState(props.value);
    return (
      <SettingsPathInput
        value={value}
        candidates={props.candidates}
        label="Project JDK"
        placeholder="Automatic"
        onChange={(next) => {
          changes.push(next);
          setValue(next);
        }}
      />
    );
  }
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () =>
      mountedRoot.render(
        <LocaleProvider language="en-US">
          <ProjectPath />
        </LocaleProvider>,
      ),
    );
    const input = host.querySelector<HTMLInputElement>('input[aria-label="Project JDK"]')!;
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    const edit = async (value: string) =>
      act(async () => {
        setValue.call(input, value);
        input.dispatchEvent(
          new window.InputEvent("input", { bubbles: true, inputType: "insertText" }),
        );
      });
    const press = async (key: string) =>
      act(async () => {
        input.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
      });
    await act(async () => input.focus());
    await verify({ input, changes, edit, press });
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  }
}

test("Escape preserves a custom toolchain draft while manual edits and clearing still work", async () => {
  await withPathInput(
    { value: "C:/toolchains/initial-jdk", candidates: [] },
    async ({ input, changes, edit, press }) => {
      await edit("C:/toolchains/custom-jdk");
      expect(changes).toEqual(["C:/toolchains/custom-jdk"]);
      expect(input.getAttribute("aria-expanded")).toBe("false");
      await press("Escape");
      expect(input.value).toBe("C:/toolchains/custom-jdk");
      expect(changes).toEqual(["C:/toolchains/custom-jdk"]);
      await edit("C:/toolchains/another-jdk");
      expect(input.value).toBe("C:/toolchains/another-jdk");
      await edit("");
      expect(input.value).toBe("");
      expect(changes[changes.length - 1]).toBe("");
    },
  );
});

const candidates = [
  { path: "C:/toolchains/jdk-17", version: "17" },
  { path: "C:/toolchains/jdk-21", version: "21" },
];

test("keyboard selection commits a suggested path and still accepts an unlisted path", async () => {
  await withPathInput({ value: "", candidates }, async ({ input, changes, edit, press }) => {
    await press("ArrowDown");
    expect(input.getAttribute("aria-expanded")).toBe("true");
    const options = Array.from(document.querySelectorAll<HTMLElement>('[role="option"]'));
    expect(options).toHaveLength(2);
    expect(options[0]!.textContent).toContain(candidates[0]!.path);
    expect(options[1]!.textContent).toContain(candidates[1]!.path);
    await press("ArrowDown");
    expect(input.getAttribute("aria-activedescendant")).toBe(options[1]!.id);
    expect(input.value).toBe("");
    expect(changes).toEqual([]);

    await press("Enter");
    expect(input.value).toBe(candidates[1]!.path);
    expect(changes[changes.length - 1]).toBe(candidates[1]!.path);
    expect(input.getAttribute("aria-expanded")).toBe("false");

    await edit("C:/custom/runtime");
    expect(input.value).toBe("C:/custom/runtime");
    expect(changes[changes.length - 1]).toBe("C:/custom/runtime");
    expect(input.getAttribute("aria-expanded")).toBe("false");
    const beforeEscape = [...changes];
    await press("Escape");
    expect(input.value).toBe("C:/custom/runtime");
    expect(changes).toEqual(beforeEscape);
  });
});

test("Escape dismisses matching candidates without selecting or clearing the draft, then editing can resume", async () => {
  await withPathInput(
    { value: candidates[0]!.path, candidates },
    async ({ input, changes, edit, press }) => {
      await edit("C:/toolchains/");
      expect(input.getAttribute("aria-expanded")).toBe("true");
      await press("ArrowDown");
      expect(input.getAttribute("aria-activedescendant")).toBeTruthy();
      const beforeEscape = [...changes];
      await press("Escape");
      expect(input.getAttribute("aria-expanded")).toBe("false");
      expect(input.value).toBe("C:/toolchains/");
      expect(changes).toEqual(beforeEscape);
      await press("Escape");
      expect(input.value).toBe("C:/toolchains/");
      expect(changes).toEqual(beforeEscape);

      await edit("C:/toolchains/jdk-2");
      expect(input.getAttribute("aria-expanded")).toBe("true");
      const options = Array.from(document.querySelectorAll<HTMLElement>('[role="option"]'));
      expect(options).toHaveLength(1);
      expect(options[0]!.textContent).toContain(candidates[1]!.path);
      await press("ArrowDown");
      await press("Enter");
      expect(input.value).toBe(candidates[1]!.path);
      expect(changes[changes.length - 1]).toBe(candidates[1]!.path);

      await edit("");
      expect(input.value).toBe("");
      expect(changes[changes.length - 1]).toBe("");
      expect(input.getAttribute("aria-expanded")).toBe("false");
      await press("ArrowDown");
      expect(input.getAttribute("aria-expanded")).toBe("true");
      await press("Escape");
      expect(input.getAttribute("aria-expanded")).toBe("false");
      expect(input.value).toBe("");
      expect(changes[changes.length - 1]).toBe("");
    },
  );
});
