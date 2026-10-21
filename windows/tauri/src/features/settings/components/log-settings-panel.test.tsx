import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import * as logApi from "@/features/logging/log-api";
import * as dialogs from "@/ui/dialog";
import * as fileDialogs from "@tauri-apps/plugin-dialog";
import * as logBuffer from "@/features/settings/services/lithe-log-service";
import workflowFixture from "../../../../../../shared/fixtures/diagnostics/logging-ui-v1.json";
import { createTranslator } from "@/i18n/locale";
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

for (const language of ["en-US", "zh-CN"] as const) {
  test(`the ${language} workflow shows scope, refreshes after clearing and releases every preview`, async () => {
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    const host = document.createElement("div");
    let root: Root | undefined;
    const t = createTranslator(language);
    const initial: logApi.LogSettingsSnapshot = {
      default_path: "fixture/logs",
      configured_path: null,
      effective_path: "fixture/logs",
      fallback_reason: null,
      diagnostic_enabled: false,
    };
    let currentSettings = initial;
    let cleared = false;
    const notices: string[] = [];
    const settings = spyOn(logApi, "getLogSettings").mockImplementation(
      async () => currentSettings,
    );
    const query = spyOn(logApi, "queryLitheLogs").mockImplementation(async () => ({
      content: cleared ? "" : "initial evidence",
      truncated: !cleared,
      matchedLines: cleared ? 0 : 1,
    }));
    const diagnostic = spyOn(logApi, "setDiagnosticLogging").mockImplementation(async (enabled) => {
      currentSettings = {
        ...initial,
        diagnostic_enabled: enabled,
        diagnostic_category: "language",
      };
      return currentSettings;
    });
    const clear = spyOn(logApi, "clearLitheLogs").mockImplementation(async () => {
      cleared = true;
      return { deleted_files: 2, freed_bytes: 100 };
    });
    const refreshBuffer = spyOn(logBuffer, "refreshOpenLitheLogBuffer").mockResolvedValue(true);
    const confirmation = spyOn(dialogs, "showConfirmDialog").mockResolvedValue(false);
    const save = spyOn(fileDialogs, "save").mockResolvedValue(null);
    const preview = spyOn(logApi, "previewDiagnosticBundle").mockResolvedValue({
      snapshotId: "fixture-snapshot",
      manifest: {
        schemaVersion: 1,
        generatedAtEpochMilliseconds: 0,
        environment: {
          appVersion: "1",
          osName: "Windows",
          osVersion: "fixture",
          cpuCoreCount: 4,
          memoryRssBytes: 1,
          diskFreeBytes: 1,
        },
        files: [
          { relativePath: "logs/language/session.log", sizeBytes: 10, description: "fixture" },
        ],
      },
    });
    const discard = spyOn(logApi, "discardDiagnosticBundle").mockResolvedValue(undefined);
    const archive = spyOn(logApi, "exportDiagnosticBundle").mockResolvedValue({
      destinationPath: "fixture/bundle.zip",
      includedRelativePaths: ["logs/language/session.log"],
      totalSizeBytes: 10,
    });
    const notifications = spyOn(toast, "useToast").mockReturnValue({
      showToast: (notice) => {
        notices.push(notice.type ?? "info");
        return "fixture-toast";
      },
      updateToast: () => {},
      dismissToast: () => {},
      hasToast: () => false,
    });
    const button = (label: string) => {
      const element = Array.from(host.querySelectorAll("button")).find(
        (entry) => entry.textContent === label,
      );
      expect(element !== undefined).toBe(true);
      return element!;
    };
    try {
      environment.IS_REACT_ACT_ENVIRONMENT = true;
      document.body.append(host);
      root = createRoot(host);
      const mounted = root;
      await act(async () =>
        mounted.render(
          <LocaleProvider language={language}>
            <LogSettingsPanel onClose={() => {}} />
          </LocaleProvider>,
        ),
      );
      expect(host.querySelector('[role="log"]')?.textContent).toBe("initial evidence");
      expect(host.textContent).toContain(t("settings.logs.incomplete"));
      expect(Array.from(host.querySelectorAll("h3"), (entry) => entry.textContent)).toEqual(
        [
          "settings.logs.timeline",
          "settings.logs.diagnostics",
          "settings.logs.locations",
          "settings.logs.retention",
          "settings.logs.diagnosticBundle",
        ].map((key) => t(key)),
      );
      if (language === "en-US") {
        expect(Array.from(host.querySelectorAll("h3"), (entry) => entry.textContent)).toEqual(
          workflowFixture.sections,
        );
      }
      expect(query.mock.calls[0]?.[0]).toMatchObject({
        session: workflowFixture.defaults.session,
        minimumLevel: workflowFixture.defaults.minimumLevel,
      });
      await act(async () => host.querySelector<HTMLButtonElement>('[role="switch"]')!.click());
      expect(diagnostic.mock.calls[0]).toEqual([true, null]);
      expect(host.textContent).toContain(
        t("settings.logs.diagnosticOn", { module: t("settings.logs.category.language") }),
      );
      await act(async () => button(t("settings.logs.clearLogs")).click());
      expect(clear).not.toHaveBeenCalled();
      expect(confirmation.mock.calls[0]?.[0]).toBe(t("settings.logs.clearPrompt"));
      confirmation.mockResolvedValue(true);
      await act(async () => button(t("settings.logs.clearLogs")).click());
      expect(clear).toHaveBeenCalledTimes(1);
      expect(host.querySelector('[role="log"]')?.textContent).toBe(t("settings.logs.empty"));
      // Cancel at the save dialog: the preview is released without exporting.
      await act(async () => button(t("settings.logs.previewExport")).click());
      expect(discard).toHaveBeenCalledWith("fixture-snapshot");
      expect(archive).not.toHaveBeenCalled();
      save.mockResolvedValue("fixture/bundle.zip");
      await act(async () => button(t("settings.logs.previewExport")).click());
      expect(archive).toHaveBeenCalledWith("fixture/bundle.zip", "fixture-snapshot");
      expect(preview.mock.calls[0]?.[0]).toMatchObject({
        session: "current",
        minimumLevel: "info",
      });
      archive.mockRejectedValue(new Error("synthetic archive failure"));
      await act(async () => button(t("settings.logs.previewExport")).click());
      expect(discard).toHaveBeenCalledTimes(3);
      expect(notices).toContain("error");
      expect(button(t("settings.logs.previewExport")).disabled).toBe(false);
    } finally {
      try {
        await act(async () => root?.unmount());
      } finally {
        for (const spy of [
          settings,
          query,
          diagnostic,
          clear,
          refreshBuffer,
          confirmation,
          save,
          preview,
          discard,
          archive,
          notifications,
        ])
          spy.mockRestore();
        host.remove();
        if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
        else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      }
    }
  });
}
