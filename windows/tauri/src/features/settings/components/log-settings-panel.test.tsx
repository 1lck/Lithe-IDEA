import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import * as logApi from "@/features/logging/log-api";
import * as toast from "@/features/layout/contexts/toast-context";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
const restoreDom = installHappyDom();
afterAll(restoreDom);
// React's browser event support must initialize after DOM globals exist.
const { createRoot } = await import("react-dom/client");
const { LogSettingsPanel } = await import("./log-settings-panel");

for (const outcome of ["success", "failure"] as const) {
  test(`filter changes during a ${outcome} refresh release busy and discard stale results`, async () => {
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    const host = document.createElement("div");
    let root: Root | undefined;
    let resolve!: (value: logApi.LogTimeline) => void;
    let reject!: (reason: Error) => void;
    const pending = new Promise<logApi.LogTimeline>((complete, fail) => {
      resolve = complete;
      reject = fail;
    });
    const settings = spyOn(logApi, "getLogSettings").mockResolvedValue({
      default_path: "fixture/logs",
      configured_path: null,
      effective_path: "fixture/logs",
      fallback_reason: null,
      diagnostic_enabled: false,
    });
    const query = spyOn(logApi, "queryLitheLogs")
      .mockReturnValueOnce(pending)
      .mockResolvedValue({ content: "fresh evidence", truncated: false, matchedLines: 1 });
    const showToast = () => "fixture-toast";
    const notifications = spyOn(toast, "useToast").mockReturnValue({
      showToast,
      updateToast: () => {},
      dismissToast: () => {},
      hasToast: () => false,
    });
    try {
      environment.IS_REACT_ACT_ENVIRONMENT = true;
      document.body.append(host);
      root = createRoot(host);
      const mounted = root;
      await act(async () =>
        mounted.render(
          <LocaleProvider language="en-US">
            <LogSettingsPanel onClose={() => {}} />
          </LocaleProvider>,
        ),
      );
      const refresh = Array.from(host.querySelectorAll("button")).find((button) =>
        button.textContent?.includes("Refresh logs"),
      )!;
      expect(refresh).toBeDefined();
      await act(async () => refresh.click());
      expect(refresh.disabled).toBe(true);
      const search = host.querySelector<HTMLInputElement>(
        'input[aria-label="Filter log messages"]',
      )!;
      expect(search).toBeDefined();
      const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      await act(async () => {
        setValue.call(search, "new filter");
        search.dispatchEvent(
          new window.InputEvent("input", { bubbles: true, inputType: "insertText" }),
        );
      });
      await act(async () => {
        if (outcome === "success")
          resolve({ content: "stale evidence", truncated: false, matchedLines: 1 });
        else reject(new Error("stale failure"));
      });
      expect(refresh.disabled).toBe(false);
      expect(host.querySelector('[role="log"]') === null).toBe(true);
      await act(async () => refresh.click());
      expect(query.mock.calls[1]?.[0].search).toBe("new filter");
      expect(host.querySelector('[role="log"]')?.textContent).toBe("fresh evidence");
    } finally {
      // Resolve even after a failed assertion so no native request outlives this test.
      resolve({ content: "", truncated: false, matchedLines: 0 });
      try {
        await act(async () => root?.unmount());
      } finally {
        query.mockRestore();
        settings.mockRestore();
        notifications.mockRestore();
        host.remove();
        if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
        else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      }
    }
  });
}
