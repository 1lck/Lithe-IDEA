import { expect, spyOn, test } from "bun:test";
import * as app from "@tauri-apps/api/app";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useUpdateStore } from "../stores/update.store";
import { SettingsPanel } from "./settings-panels";

test("settings only claims the application is current after a successful check", async () => {
  const restoreDom = installHappyDom();
  const previous = useUpdateStore.getState();
  const version = spyOn(app, "getVersion").mockResolvedValue("0.5.6");
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  const root = createRoot(container);
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    useUpdateStore.setState({ status: "idle", error: null, updateInfo: null });
    await act(async () => {
      root.render(
        <LocaleProvider language="en-US">
          <SettingsPanel category="updates" onClose={() => {}} />
        </LocaleProvider>,
      );
    });
    const message = () => container.querySelector('[role="status"]')?.textContent;
    expect(message()).not.toContain("up to date");
    await act(async () => {
      useUpdateStore.setState({ status: "checking" });
    });
    expect(message()).toBe("Checking for updates…");
    await act(async () => {
      useUpdateStore.setState({ status: "failed", error: "Offline" });
    });
    expect(message()).not.toContain("up to date");
    await act(async () => {
      useUpdateStore.setState({ status: "upToDate", error: null });
    });
    expect(message()).toBe("Lithe is up to date.");
    // Dismissal or suppression after a previous successful check must clear that claim.
    await act(async () => {
      useUpdateStore.setState({ status: "idle" });
    });
    expect(message()).not.toContain("up to date");
  } finally {
    try {
      await act(async () => root.unmount());
    } finally {
      useUpdateStore.setState(previous, true);
      version.mockRestore();
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
