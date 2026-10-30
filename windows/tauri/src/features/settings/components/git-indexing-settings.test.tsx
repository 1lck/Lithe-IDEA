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
import { WorkspaceIndexingSettings } from "./workspace-indexing-settings";
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
    const settings = {
      gitIgnoreEnabled: false,
      includedDirectories: ["vendor/examples"],
      previousRoles: { vendor: "sources" },
    };
    const configure = spyOn(indexing, "configureWorkspaceIndexing").mockImplementation(
      async () => ({
        revision: 1,
        excludedDirectories: {},
        gitIgnoreFailed: false,
      }),
    );
    const host = document.createElement("div");
    const root = createRoot(host);
    const t = createTranslator(language);
    const checkbox = () =>
      Array.from(host.querySelectorAll<HTMLElement>('[role="checkbox"]')).find(
        (element) =>
          element.getAttribute("aria-label") === t("indexing.autoGit") ||
          document.getElementById(element.getAttribute("aria-labelledby") ?? "")?.textContent ===
            t("indexing.autoGit"),
      )!;
    const render = () =>
      root.render(
        <WorkspaceStoreScopeContext.Provider value={workspaceId}>
          <LocaleProvider language={language}>
            <GitSettings />
          </LocaleProvider>
        </WorkspaceStoreScopeContext.Provider>,
      );
    try {
      environment.IS_REACT_ACT_ENVIRONMENT = true;
      document.body.append(host);
      window.localStorage.setItem(
        indexing.indexingSettingsStorageKey(first),
        JSON.stringify(settings),
      );
      const fileSystem = useFileSystemStore.getStore(workspaceId);
      const repositories = useRepositoryStore.getStore(workspaceId);
      fileSystem.setState({ rootFolderPath: first });
      useProjectStore.getStore(workspaceId).setState({ rootFolderPath: first });
      repositories.setState({ activeRepoPath: nested });
      await act(async () => render());

      expect(checkbox()).toBeDefined();
      expect(checkbox().getAttribute("aria-checked")).toBe("false");
      expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(first))).toBe(
        JSON.stringify(settings),
      );
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
      expect(indexing.readIndexingSettings(first).includedDirectories).toEqual(
        settings.includedDirectories,
      );

      const failedWrite = spyOn(indexing, "writeIndexingSettings").mockImplementationOnce(() => {
        throw new Error("fixture storage is full");
      });
      try {
        await act(async () => checkbox().click());
        expect(host.querySelector('[role="alert"]')?.textContent).toBe(t("indexing.writeFailed"));
        expect(indexing.readIndexingSettings(first)).toEqual({
          ...settings,
          gitIgnoreEnabled: true,
        });
        expect(checkbox().getAttribute("aria-checked")).toBe("true");
      } finally {
        failedWrite.mockRestore();
      }

      for (const remote of ["remote://fixture/project", "wsl://fixture/project"]) {
        const raw = JSON.stringify({ ...settings, gitIgnoreEnabled: false });
        window.localStorage.setItem(indexing.indexingSettingsStorageKey(remote), raw);
        const calls = configure.mock.calls.length;
        await act(async () => fileSystem.setState({ rootFolderPath: remote }));
        expect(checkbox().getAttribute("aria-disabled")).toBe("true");
        expect(checkbox().getAttribute("aria-checked")).toBe("false");
        expect(host.textContent).toContain(t("indexing.remoteUnsupported"));
        await act(async () => checkbox().click());
        expect(configure.mock.calls.length).toBe(calls);
        expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(remote))).toBe(raw);
      }
      await act(async () => fileSystem.setState({ rootFolderPath: first }));
      expect(checkbox().getAttribute("aria-disabled")).not.toBe("true");
      for (const raw of ["not-json", "{}", "null"]) {
        window.localStorage.setItem(indexing.indexingSettingsStorageKey(first), raw);
        await act(async () =>
          window.dispatchEvent(new window.CustomEvent(indexing.indexingEvent, { detail: first })),
        );
        expect(checkbox().getAttribute("aria-disabled")).toBe("true");
        expect(host.querySelector('[role="alert"]')?.textContent).toBe(
          t("indexing.invalidSettings"),
        );
        expect(window.localStorage.getItem(indexing.indexingSettingsStorageKey(first))).toBe(raw);
      }
    } finally {
      try {
        await act(async () => root.unmount());
      } finally {
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

test("a late local configuration cannot replace the remote capability state", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  let finish!: (status: indexing.IndexingStatus) => void;
  const pending = new Promise<indexing.IndexingStatus>((resolve) => {
    finish = resolve;
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockImplementation(() => pending);
  const host = document.createElement("div");
  const root = createRoot(host);
  const render = (path: string) =>
    root.render(
      <LocaleProvider language="zh-CN">
        <WorkspaceIndexingSettings root={path} />
      </LocaleProvider>,
    );
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    await act(async () => render("C:/fixture"));
    await act(async () => render("remote://fixture/project"));
    await act(async () => finish({ revision: 1, excludedDirectories: {}, gitIgnoreFailed: true }));
    expect(configure).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain(createTranslator("zh-CN")("indexing.remoteUnsupported"));
    expect(host.querySelector('[role="alert"]')).toBeNull();
  } finally {
    finish({ revision: 1, excludedDirectories: {}, gitIgnoreFailed: false });
    try {
      await act(async () => root.unmount());
    } finally {
      configure.mockRestore();
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
