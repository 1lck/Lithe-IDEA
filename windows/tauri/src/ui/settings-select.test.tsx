import { expect, spyOn, test } from "bun:test";
import { Select as SelectPrimitive } from "@base-ui/react/select";
import { act, useState, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import SettingsSelect from "./settings-select";

test("automatic configuration remains selected and can be restored after choosing an explicit value", async () => {
  const restoreDom = installHappyDom();
  // Portal placement needs a browser; keep the actual Root, options and selection logic here.
  const portal = spyOn(SelectPrimitive, "Portal").mockImplementation(
    (({ children }: ComponentProps<typeof SelectPrimitive.Portal>) => (
      <div>{children}</div>
    )) as typeof SelectPrimitive.Portal,
  );
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  const changes: string[] = [];
  let root: Root | undefined;
  function Configuration() {
    const [value, setValue] = useState("");
    return (
      <SettingsSelect
        id="toolchain"
        open
        value={value}
        options={[
          { value: "", label: "Automatic" },
          { value: "explicit", label: "Explicit toolchain" },
          { value: "unavailable", label: "Unavailable toolchain", disabled: true },
        ]}
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
          <label htmlFor="toolchain">Toolchain</label>
          <Configuration />
        </LocaleProvider>,
      ),
    );
    const options = Array.from(document.querySelectorAll<HTMLElement>('[role="option"]'));
    const automatic = options.find((option) => option.textContent === "Automatic")!;
    const explicit = options.find((option) => option.textContent === "Explicit toolchain")!;
    const unavailable = options.find((option) => option.textContent === "Unavailable toolchain")!;
    expect(automatic).toBeDefined();
    expect(automatic.getAttribute("aria-selected")).toBe("true");
    expect(host.querySelector("#toolchain")?.hasAttribute("aria-label")).toBe(false);
    await act(async () => explicit.click());
    expect(changes).toEqual(["explicit"]);
    await act(async () => unavailable.click());
    expect(changes).toEqual(["explicit"]);
    await act(async () => automatic.click());
    expect(changes).toEqual(["explicit", ""]);
    expect(automatic.getAttribute("aria-selected")).toBe("true");
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      portal.mockRestore();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
