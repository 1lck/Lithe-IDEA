import { afterAll, expect, test } from "bun:test";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { PluginSettingsReloads, type PluginReloadReceipt } from "./declarative-plugin-reload";
import { DeclarativePluginReloadNotices } from "./declarative-plugin-reload-notices";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const receipt: PluginReloadReceipt = {
  pluginId: "example.plugin",
  workspacePath: "/fixture/workspace",
  expectedIdentity: "saved",
  expectedPackageIdentity: "approved-package",
};

test("a failed reload retains its retry control when the originating settings page disappears", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  let root: Root | null = null;
  let attempts = 0;
  let refreshes = 0;
  let revokePage = () => {};
  const reloads = new PluginSettingsReloads({
    reload: async () => {
      attempts++;
      // The real lifecycle revokes the dynamic page before waiting for stop.
      revokePage();
      if (attempts === 1) throw new Error("process still running");
    },
    refresh: async () => {
      refreshes++;
    },
  });
  reloads.require(receipt);
  function SettingsSurface() {
    const [page, setPage] = useState(true);
    revokePage = () => setPage(false);
    return (
      <LocaleProvider>
        {page && <div data-originating-page="" />}
        <DeclarativePluginReloadNotices reloads={reloads} />
      </LocaleProvider>
    );
  }
  try {
    await act(async () => {
      root = createRoot(host);
      root.render(<SettingsSurface />);
    });
    const confirm = () => host.querySelector<HTMLButtonElement>("[data-plugin-reload-confirm]")!;
    expect(confirm()).not.toBeNull();
    await act(async () => {
      confirm().click();
    });
    expect(host.querySelector("[data-originating-page]")).toBeNull();
    expect(host.querySelector("[role=alert]")?.textContent).toContain("process still running");
    expect(confirm().disabled).toBe(false);
    expect(reloads.state(receipt.pluginId)?.receipt).toBe(receipt);
    await act(async () => {
      confirm().click();
    });
    expect(attempts).toBe(2);
    expect(refreshes).toBe(1);
    expect(host.querySelector("[data-plugin-reload-notices]")).toBeNull();
  } finally {
    await act(async () => {
      root?.unmount();
    });
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
}, 1000);

test("Later cancels an unconfirmed reload without invoking the native barrier", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  let root: Root | null = null;
  let attempts = 0;
  const reloads = new PluginSettingsReloads({
    reload: async () => {
      attempts++;
    },
    refresh: async () => {},
  });
  reloads.require(receipt);
  try {
    await act(async () => {
      root = createRoot(host);
      root.render(
        <LocaleProvider>
          <DeclarativePluginReloadNotices reloads={reloads} />
        </LocaleProvider>,
      );
    });
    await act(async () => {
      host.querySelector<HTMLButtonElement>("[data-plugin-reload-postpone]")!.click();
    });
    expect(attempts).toBe(0);
    expect(host.querySelector("[data-plugin-reload-notices]")).toBeNull();
  } finally {
    await act(async () => {
      root?.unmount();
    });
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
}, 1000);
