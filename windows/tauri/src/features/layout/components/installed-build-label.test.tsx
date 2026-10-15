import { expect, spyOn, test } from "bun:test";
import * as app from "@tauri-apps/api/app";
import { act } from "react";
import { createRoot } from "react-dom/client";
import buildTimeFixture from "../../../../../../shared/fixtures/updates/build-time-v1.json";
import { useRecentFoldersStore } from "@/features/file-system/stores/recent-folders.store";
import { SettingsPanel } from "@/features/settings/components/settings-panels";
import { useUpdateStore } from "@/features/settings/stores/update.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { WelcomeScreen } from "./welcome-screen";

test("settings and welcome show localized installed build time independently of the Stable preference", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousChannel = process.env.VITE_UPDATE_CHANNEL;
  const previousTimestamp = process.env.VITE_BUILD_TIMESTAMP;
  const previousUpdate = useUpdateStore.getState();
  const previousRecents = useRecentFoldersStore.getState().recentFolders;
  const versionQuery = spyOn(app, "getVersion").mockResolvedValue("123.4");
  const workspaceId = "installed-build-label-test";
  const container = document.createElement("div");
  const root = createRoot(container);
  const entry = buildTimeFixture.cases[0]!;

  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    process.env.VITE_UPDATE_CHANNEL = "autobuild";
    useUpdateStore.setState({ channel: "stable", status: "idle", updateInfo: null, error: null });
    useRecentFoldersStore.setState({ recentFolders: [] });
    for (const timestamp of [entry.timestamp, "2026-02-29T12:00:00Z", undefined]) {
      if (timestamp === undefined) delete process.env.VITE_BUILD_TIMESTAMP;
      else process.env.VITE_BUILD_TIMESTAMP = timestamp;
      for (const language of ["en-US", "zh-CN"] as const) {
        const expected = timestamp === entry.timestamp
          ? `AutoBuild — ${language === "en-US" ? "Built at" : "构建自"} ${entry.display}`
          : "AutoBuild";
        for (const surface of ["settings", "welcome"] as const) {
          await act(async () => {
            root.render(
              <WorkspaceStoreScopeContext.Provider value={workspaceId}>
                <LocaleProvider language={language}>
                  {surface === "settings" ? <SettingsPanel category="updates" onClose={() => {}} /> : <WelcomeScreen />}
                </LocaleProvider>
              </WorkspaceStoreScopeContext.Provider>,
            );
          });
          expect(container.textContent).toContain(expected);
          expect(container.textContent).not.toContain("123.4");
          if (timestamp !== entry.timestamp) {
            expect(container.textContent).not.toContain("Built at");
            expect(container.textContent).not.toContain("构建自");
          }
          expect<string>(useUpdateStore.getState().channel).toBe("stable");
          expect(container.textContent).not.toContain("Lithe is up to date.");
        }
      }
    }
  } finally {
    try {
      await act(async () => root.unmount());
    } finally {
      if (previousChannel === undefined) delete process.env.VITE_UPDATE_CHANNEL;
      else process.env.VITE_UPDATE_CHANNEL = previousChannel;
      if (previousTimestamp === undefined) delete process.env.VITE_BUILD_TIMESTAMP;
      else process.env.VITE_BUILD_TIMESTAMP = previousTimestamp;
      useUpdateStore.setState(previousUpdate, true);
      useRecentFoldersStore.setState({ recentFolders: previousRecents });
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      versionQuery.mockRestore();
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
