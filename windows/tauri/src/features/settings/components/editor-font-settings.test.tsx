import { expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { useMonacoEditorSettings } from "@/features/editor/engines/monaco/use-monaco-editor-settings";
import { useEditorSettingsStore } from "@/features/editor/stores/settings.store";
import { useZoomStore } from "@/features/window/stores/zoom.store";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as select from "@/ui/select";
import * as persistence from "../lib/settings-persistence";
import { useSettingsStore } from "../stores/settings.store";
import { useFontStore } from "../stores/font.store";
import { FontSelector } from "./font-selector";
import { MacSettingsPanel } from "./macos-settings-panels";

const fonts = [
  { family: "Consolas", name: "Consolas", style: "Regular", is_monospace: true },
  { family: "Microsoft YaHei", name: "微软雅黑", style: "Regular", is_monospace: false },
];

// Exercise settings and catalog ownership with deterministic native select events.
// The shared combobox's portal/layout is separately exercised in the isolated GUI.
async function withControls(
  run: (
    container: HTMLDivElement,
    render: (node: React.ReactNode) => Promise<void>,
  ) => Promise<void>,
) {
  const restoreDom = installHappyDom();
  const previousFont = useFontStore.getState();
  const previousSettings = useSettingsStore.getState();
  const previousEditor = useEditorSettingsStore.getState();
  const previousZoom = useZoomStore.getState();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const catalog = mock(async () => {});
  useFontStore.setState({
    availableFonts: fonts,
    monospaceFonts: [fonts[0]],
    isLoading: false,
    error: null,
    actions: { ...previousFont.actions, loadAvailableFonts: catalog, loadMonospaceFonts: catalog },
  });
  const control = spyOn(select, "default").mockImplementation((props) => (
    <select
      aria-label={props["aria-label"]}
      value={props.value}
      data-searchable={String(props.searchable)}
      onChange={(event) => props.onChange(event.target.value)}
    >
      {props.options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  ));
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    await run(container, async (node) => {
      await act(async () => root.render(<LocaleProvider language="en-US">{node}</LocaleProvider>));
    });
    expect(catalog).toHaveBeenCalledWith(true);
  } finally {
    try {
      await act(async () => root.unmount());
    } finally {
      control.mockRestore();
      useFontStore.setState(previousFont, true);
      useSettingsStore.setState(previousSettings, true);
      useEditorSettingsStore.setState(previousEditor, true);
      useZoomStore.setState(previousZoom, true);
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
}

test("font selector retains configured choice during pending, failed and empty catalogs", async () => {
  await withControls(async (container, render) => {
    const changed = mock(() => {});
    await render(<FontSelector value="User Installed 字体" onChange={changed} />);
    for (const state of [
      { isLoading: true, error: null },
      { isLoading: false, error: "Unavailable" },
      { isLoading: false, error: null },
    ]) {
      await act(async () => useFontStore.setState({ ...state, availableFonts: [] }));
      expect(container.querySelector("select")?.value).toBe("User Installed 字体");
      expect(changed).not.toHaveBeenCalled();
    }
    await act(async () => useFontStore.setState({ availableFonts: fonts }));
    expect(container.textContent).toContain("微软雅黑 (Microsoft YaHei)");
    const choice = container.querySelector("select")!;
    expect(choice.dataset.searchable).toBe("true");
    await act(async () => {
      choice.value = "Microsoft YaHei";
      choice.dispatchEvent(new Event("change", { bubbles: true }));
    });
    expect(changed).toHaveBeenCalledTimes(1);
    expect(changed).toHaveBeenCalledWith("Microsoft YaHei");
  });
});

function MonacoSettingsProbe() {
  return <output data-editor-options>{JSON.stringify(useMonacoEditorSettings())}</output>;
}

test("active editor panel persists font choices and size steps, applies live options, and restores bounds", async () => {
  const saved = spyOn(persistence, "debouncedSaveSettingsToStore").mockImplementation(() => {});
  try {
    await withControls(async (container, render) => {
      useZoomStore.setState({ editorZoomLevel: 1 });
      useSettingsStore.setState({
        settings: { ...useSettingsStore.getState().settings, fontSize: 23 },
      });
      const showEditor = (key: string) =>
        render(
          <div key={key}>
            <MacSettingsPanel category="editor" onClose={() => {}} />
            <MonacoSettingsProbe />
          </div>,
        );
      await showEditor("initial");
      const family = container.querySelector<HTMLSelectElement>(
        'select[aria-label="Editor Font Family"]',
      )!;
      expect(family).not.toBeNull();
      expect([...family.options].some((option) => option.value === "Microsoft YaHei")).toBe(true);
      await act(async () => {
        family.value = "Microsoft YaHei";
        family.dispatchEvent(new Event("change", { bubbles: true }));
      });
      expect(useSettingsStore.getState().settings.fontFamily).toBe("Microsoft YaHei");
      expect(saved).toHaveBeenCalledWith({ fontFamily: "Microsoft YaHei" });

      const size = container.querySelector<HTMLInputElement>('input[aria-label="Font size"]')!;
      expect(size.type).toBe("text");
      // Exercise the user's real step action, independent of Base UI's cached SSR/browser mode.
      const increase = container.querySelector<HTMLButtonElement>(
        'button[aria-label="Increase value"]',
      )!;
      await act(async () => increase.click());
      expect(useSettingsStore.getState().settings.fontSize).toBe(24);
      expect(size.value).toBe("24");
      expect(saved).toHaveBeenCalledWith({ fontSize: 24 });

      const toggle = container.querySelector<HTMLElement>(
        '[role="switch"][aria-label="Font Ligatures"]',
      )!;
      expect(toggle).not.toBeNull();
      const before = useSettingsStore.getState().settings.editorFontLigatures;
      await act(async () => toggle.click());
      expect(useSettingsStore.getState().settings.editorFontLigatures).toBe(!before);
      expect(saved).toHaveBeenCalledWith({ editorFontLigatures: !before });
      const options = JSON.parse(container.querySelector("[data-editor-options]")!.textContent!);
      expect(options).toMatchObject({
        fontFamily: "Microsoft YaHei",
        fontSize: 24,
        editorFontLigatures: !before,
      });
      const preview = container.querySelector<HTMLElement>(
        'pre[aria-label="Editor font preview"]',
      )!;
      expect(preview.style.fontSize).toBe("24px");
      expect(preview.style.fontVariantLigatures).toBe(!before ? "normal" : "none");
      // Reopening settings must load persisted boundary values into the shared control.
      await act(async () => {
        await useSettingsStore.getState().actions.updateSetting("fontSize", 72);
      });
      await showEditor("upper-bound");
      expect(
        container.querySelector<HTMLInputElement>('input[aria-label="Font size"]')!.value,
      ).toBe("72");
      expect(
        container.querySelector<HTMLButtonElement>('button[aria-label="Increase value"]')!.disabled,
      ).toBe(true);
      await act(async () => {
        await useSettingsStore.getState().actions.updateSetting("fontSize", 6);
      });
      await showEditor("lower-bound");
      expect(
        container.querySelector<HTMLInputElement>('input[aria-label="Font size"]')!.value,
      ).toBe("6");
      expect(
        container.querySelector<HTMLButtonElement>('button[aria-label="Decrease value"]')!.disabled,
      ).toBe(true);
    });
  } finally {
    saved.mockRestore();
  }
});
