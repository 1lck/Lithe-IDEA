import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as core from "@/core/lithe-core-client";
import * as numberInput from "@/ui/number-input";
import { useSettingsStore } from "../stores/settings.store";
import { JavaImportTimeoutSettings } from "./java-import-timeout-settings";

test("timeout edits remain drafts, save survives reopening, and reset removes the override", async () => {
  const restoreDom = installHappyDom();
  const previous = useSettingsStore.getState();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const writes: unknown[] = [];
  const resolver = spyOn(core, "executeCore").mockImplementation(async (request) => {
    const minutes = (request.payload as { minutes?: number }).minutes ?? 10;
    return {
      id: request.id,
      ok: true,
      data: { minutes, milliseconds: minutes * 60_000, minimumMinutes: 1, maximumMinutes: 120 },
    } as never;
  });
  const input = spyOn(numberInput, "default").mockImplementation(({ value, onChange }) => (
    <button data-input onClick={() => onChange?.(60)}>
      {value}
    </button>
  ));
  const container = document.createElement("div");
  const root = createRoot(container);
  const render = () =>
    root.render(
      <LocaleProvider language="en-US">
        <JavaImportTimeoutSettings />
      </LocaleProvider>,
    );
  const button = (label: string) =>
    Array.from(container.querySelectorAll("button")).find((item) => item.textContent === label)!;
  try {
    useSettingsStore.setState({
      settings: { ...previous.settings, javaImportTimeoutMinutes: undefined },
      actions: {
        ...previous.actions,
        updateSetting: async (key, value) => {
          writes.push(value);
          useSettingsStore.setState((state) => ({ settings: { ...state.settings, [key]: value } }));
        },
      },
    });
    await act(async () => render());
    expect(container.querySelector("[data-input]")?.textContent).toBe("10");
    expect(writes).toEqual([]);
    await act(async () => (container.querySelector("[data-input]") as HTMLElement).click());
    expect(writes).toEqual([]);
    await act(async () => root.render(null));
    await act(async () => render());
    expect(container.querySelector("[data-input]")?.textContent).toBe("10");
    await act(async () => (container.querySelector("[data-input]") as HTMLElement).click());
    await act(async () => button("Save").click());
    expect(writes).toEqual([60]);
    await act(async () => root.render(null));
    await act(async () => render());
    expect(container.querySelector("[data-input]")?.textContent).toBe("60");
    await act(async () => button("Restore default").click());
    expect(writes).toEqual([60, undefined]);
    expect(container.querySelector("[data-input]")?.textContent).toBe("10");
  } finally {
    await act(async () => root.unmount());
    input.mockRestore();
    resolver.mockRestore();
    useSettingsStore.setState(previous);
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
