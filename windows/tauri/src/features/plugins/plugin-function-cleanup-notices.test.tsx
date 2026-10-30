import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { PluginFunctionCleanupNotices } from "./plugin-function-cleanup-notices";
import { retainWebFunctionCleanup, pluginFunctionCleanup } from "./plugin-functions";
import type { FunctionContext } from "./plugin-function-session";

const restore = installHappyDom();
afterAll(restore);
const { createRoot } = await import("react-dom/client");

test("workbench cleanup notice exposes the original web function retry after its approval disappears", async () => {
  const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  const context: FunctionContext = {
    window: "main",
    windowIncarnation: 42,
    workspacePath: "/fixture/project",
    generation: 7,
    pluginId: "example.plugin",
    packageIdentity: "package",
    settingIdentity: "settings",
    actionId: "__web__:fixture:snapshot.refresh",
    functionId: "snapshot.refresh",
    operationId: "notice-original-operation",
  };
  const error = { code: "plugin.function.cleanupFailed", message: "plugin.function.cleanupFailed" };
  let succeeds = false;
  let attempts = 0;
  let root: Root | null = null;
  const receipt = retainWebFunctionCleanup(context, error, async () => {
    attempts++;
    if (!succeeds) throw error;
  });
  try {
    globals.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <LocaleProvider language="en-US">
          <PluginFunctionCleanupNotices />
        </LocaleProvider>,
      ),
    );
    expect(host.textContent).toContain("example.plugin");
    expect(host.textContent).toContain("snapshot.refresh");
    expect(host.querySelector("[data-plugin-function-action]")).toBeNull();
    const retry = () =>
      host.querySelector<HTMLButtonElement>("[data-plugin-function-cleanup] button")!;
    expect(retry().textContent).toBe("Retry Stop");
    await act(async () => {
      retry().click();
      await receipt.cancel();
    });
    expect(attempts).toBe(1);
    expect(host.querySelector("[data-plugin-function-cleanup]")).not.toBeNull();
    succeeds = true;
    await act(async () => {
      retry().click();
      await receipt.cancel();
    });
    expect(attempts).toBe(2);
    expect(host.querySelector("[data-plugin-function-cleanup]")).toBeNull();
    expect(host.childElementCount).toBe(0);
    expect(pluginFunctionCleanup.pending().includes(receipt)).toBe(false);
  } finally {
    succeeds = true;
    await act(async () => {
      await receipt.cancel();
      root?.unmount();
    });
    host.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
}, 3000);
