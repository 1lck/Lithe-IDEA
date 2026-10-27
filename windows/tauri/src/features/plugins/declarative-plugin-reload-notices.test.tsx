import { afterAll, expect, test } from "bun:test";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { PluginSettingsReloads, type PluginReloadReceipt } from "./declarative-plugin-reload";
import type { BuildModelReview } from "@/features/build-systems/build-systems-types";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { DeclarativePluginReloadNotices } = await import("./declarative-plugin-reload-notices");
const receipt: PluginReloadReceipt = {
  pluginId: "example.plugin",
  workspacePath: "/fixture/workspace",
  expectedIdentity: "saved",
  expectedPackageIdentity: "approved-package",
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

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

test("project approval is declined on notice unmount while distinct global and project rows coexist", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const controller = new AbortController();
  let root: Root | null = null;
  let accepted: boolean | undefined;
  const project = {
    ...receipt,
    scope: "project" as const,
    project: { workspaceId: "fixture", registration: 1, windowIncarnation: 1 },
  };
  const review: BuildModelReview = {
    operationId: "model",
    pluginId: receipt.pluginId,
    buildSystemId: "fixture",
    root: ".",
    workspaceRoot: receipt.workspacePath,
    generation: 1,
    executesProjectCode: true,
    mayUseNetwork: false,
  };
  const reloads = new PluginSettingsReloads({
    reload: async (_receipt, approve) => {
      accepted = await approve!(review, controller.signal);
      throw new Error("plugin.settings.reloadCancelled");
    },
    refresh: async () => {},
  });
  reloads.require(receipt);
  reloads.require(project);
  try {
    await act(async () => {
      root = createRoot(host);
      root.render(
        <LocaleProvider>
          <DeclarativePluginReloadNotices reloads={reloads} />
        </LocaleProvider>,
      );
    });
    expect(host.querySelectorAll("[data-plugin-reload]")).toHaveLength(2);
    await act(async () => {
      host
        .querySelector<HTMLButtonElement>(
          '[data-plugin-reload-scope="project"] [data-plugin-reload-confirm]',
        )!
        .click();
    });
    expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    expect(reloads.state(reloads.key(project))?.busy).toBe(true);
    await act(async () => {
      root?.unmount();
      root = null;
    });
    expect(accepted).toBe(false);
    expect(reloads.state(reloads.key(project))?.error).toContain("reloadCancelled");
    expect(reloads.state(receipt.pluginId)?.receipt).toBe(receipt);
  } finally {
    controller.abort();
    await act(async () => {
      root?.unmount();
    });
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
}, 1000);

test("project reload offers Cancel only after bounded native preflight has returned", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  const gate = deferred<void>();
  let root: Root | null = null;
  let modelPhase!: () => void;
  let signal!: AbortSignal;
  const project = {
    ...receipt,
    scope: "project" as const,
    project: { workspaceId: "fixture", registration: 1, windowIncarnation: 1 },
  };
  const reloads = new PluginSettingsReloads({
    reload: async (_receipt, _approve, currentSignal, ready) => {
      signal = currentSignal!;
      modelPhase = ready!;
      await gate.promise;
      if (signal.aborted) throw new Error("plugin.settings.reloadCancelled");
    },
    refresh: async () => {},
  });
  reloads.require(project);
  const key = reloads.key(project);
  let pending: Promise<void> = Promise.resolve();
  try {
    document.body.append(host);
    await act(async () => {
      root = createRoot(host);
      root.render(
        <LocaleProvider>
          <DeclarativePluginReloadNotices reloads={reloads} />
        </LocaleProvider>,
      );
    });
    await act(async () => {
      pending = reloads.confirm(key);
    });
    expect(reloads.state(key)?.busy).toBe(true);
    expect(host.querySelector("[data-plugin-reload-cancel]")).toBeNull();
    reloads.cancel(key);
    expect(signal.aborted).toBe(false);
    await act(async () => modelPhase());
    const cancel = host.querySelector<HTMLButtonElement>("[data-plugin-reload-cancel]")!;
    expect(cancel).not.toBeNull();
    await act(async () => cancel.click());
    expect(signal.aborted).toBe(true);
    expect(reloads.state(key)?.busy).toBe(true);
    await act(async () => {
      gate.resolve();
      await pending;
    });
    expect(reloads.state(key)?.busy).toBe(false);
    expect(reloads.state(key)?.error).toContain("reloadCancelled");
  } finally {
    gate.resolve();
    await act(async () => {
      await pending;
      root?.unmount();
    });
    host.remove();
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
}, 3000);
