import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useRepositoryStore } from "@/features/git/stores/git-repository.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { GitSettings } from "./tabs/git-settings";

test.each(["en-US", "zh-CN"] as const)(
  "Git indexing settings follow the workspace and preserve saved exceptions: %s",
  async (language) => {
    const restoreDom = installHappyDom();
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    const workspaceId = `git-indexing-${language}`;
    const first = "C:/first-project";
    const second = "C:/second-project";
    const nested = `${first}/nested-repo`;
    const settings = { gitIgnoreEnabled: false, includedDirectories: ["vendor/examples"], previousRoles: { vendor: "sources" } };
    const configure = spyOn(indexing, "configureWorkspaceIndexing").mockImplementation(async () => ({
      revision: 1, excludedDirectories: {}, gitIgnoreFailed: false,
    }));
    const host = document.createElement("div");
    const root = createRoot(host);
    const t = createTranslator(language);
    const checkbox = () => Array.from(host.querySelectorAll<HTMLElement>('[role="checkbox"]'))
      .find((element) => element.getAttribute("aria-label") === t("indexing.autoGit")
        || document.getElementById(element.getAttribute("aria-labelledby") ?? "")?.textContent === t("indexing.autoGit"))!;
    const render = () => root.render(
      <WorkspaceStoreScopeContext.Provider value={workspaceId}>
        <LocaleProvider language={language}><GitSettings /></LocaleProvider>
      </WorkspaceStoreScopeContext.Provider>,
    );
    try {
      environment.IS_REACT_ACT_ENVIRONMENT = true;
      document.body.append(host);
      window.localStorage.setItem(indexing.indexingSettingsStorageKey(first), JSON.stringify(settings));
      const fileSystem = useFileSystemStore.getStore(workspaceId);
      const repositories = useRepositoryStore.getStore(workspaceId);
      fileSystem.setState({ rootFolderPath: first });
      useProjectStore.getStore(workspaceId).setState({ rootFolderPath: first });
      repositories.setState({ activeRepoPath: nested });
      await act(async () => render());

      expect(checkbox()).toBeDefined();
      expect(checkbox().getAttribute("aria-checked")).toBe("false");
      expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(first))).toBe(JSON.stringify(settings));
      expect(configure).toHaveBeenCalledWith(first);
      expect(configure.mock.calls.every(([path]) => path !== nested)).toBe(true);
      await act(async () => checkbox().click());
      expect(indexing.readIndexingSettings(first)).toEqual({ ...settings, gitIgnoreEnabled: true });
      expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(nested))).toBeNull();

      await act(async () => fileSystem.setState({ rootFolderPath: second }));
      expect(checkbox().getAttribute("aria-checked")).toBe("true");
      // Reading a default value on the Git page must not create a saved preference.
      expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(second))).toBeNull();
      await act(async () => checkbox().click());
      expect(indexing.readIndexingSettings(second).gitIgnoreEnabled).toBe(false);
      expect(indexing.readIndexingSettings(first)).toEqual({ ...settings, gitIgnoreEnabled: true });

      await act(async () => fileSystem.setState({ rootFolderPath: undefined }));
      expect(checkbox().getAttribute("aria-disabled")).toBe("true");
      const callsWithoutProject = configure.mock.calls.length;
      await act(async () => checkbox().click());
      expect(configure.mock.calls.length).toBe(callsWithoutProject);
      await act(async () => fileSystem.setState({ rootFolderPath: first }));
      expect(checkbox().getAttribute("aria-checked")).toBe("true");
      expect(indexing.readIndexingSettings(first).includedDirectories).toEqual(settings.includedDirectories);

      const failedWrite = spyOn(indexing, "writeIndexingSettings").mockImplementationOnce(() => {
        throw new Error("fixture storage is full");
      });
      try {
        await act(async () => checkbox().click());
        expect(host.querySelector('[role="alert"]')?.textContent).toContain("fixture storage is full");
        expect(indexing.readIndexingSettings(first)).toEqual({ ...settings, gitIgnoreEnabled: true });
        expect(checkbox().getAttribute("aria-checked")).toBe("true");
      } finally { failedWrite.mockRestore(); }

      window.localStorage.setItem(indexing.indexingSettingsStorageKey(first), "not-json");
      await act(async () => window.dispatchEvent(new window.CustomEvent(indexing.indexingEvent, { detail: first })));
      expect(checkbox().getAttribute("aria-disabled")).toBe("true");
      expect(host.querySelector('[role="alert"]')).not.toBeNull();
      expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(first))).toBe("not-json");
    } finally {
      try { await act(async () => root.unmount()); }
      finally {
        host.remove();
        configure.mockRestore();
        workspaceRuntimeRegistry.removeWorkspace(workspaceId);
        if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
        else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
        restoreDom();
      }
    }
  },
);
