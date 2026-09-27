import { expect, spyOn, test } from "bun:test";
import * as dialog from "@tauri-apps/plugin-dialog";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { MavenSettingsPanel } from "./maven-settings-panel";

test("switching projects with identical saved settings discards the previous project's draft", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousTabs = useWorkspaceTabsStore.getState().projectTabs;
  const workspaceIds = ["maven-settings-draft-a", "maven-settings-draft-b"];
  const browse = spyOn(dialog, "open").mockResolvedValue("D:/team-a/settings.xml");
  const container = document.createElement("div");
  let root: Root | undefined;
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    for (const id of workspaceIds) {
      useMavenStore.getStore(id).setState((state) => ({
        root: `D:/fixture/${id}`,
        projectStatus: "ready",
        project: {
          relativePath: ".", artifactId: id, packaging: "jar",
          sourceRoots: [], modules: [], profiles: [], hasWrapper: false,
        },
        actions: { ...state.actions, resolveEffectiveConfiguration: async () => {} },
      }));
    }
    const tabs = workspaceIds.map((id, index) => ({
      id, name: id, path: `D:/fixture/${id}`, isActive: index === 0, lastOpened: 0,
    }));
    useWorkspaceTabsStore.setState({ projectTabs: tabs });
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;
    await act(async () => {
      mountedRoot.render(<LocaleProvider language="en-US"><MavenSettingsPanel /></LocaleProvider>);
    });
    const browseButton = container.querySelector<HTMLButtonElement>('button[aria-label="Browse"]');
    expect(browseButton).not.toBeNull();
    await act(async () => browseButton!.click());
    expect(container.querySelector("input")?.value).toBe("D:/team-a/settings.xml");

    await act(async () => {
      useWorkspaceTabsStore.setState({
        projectTabs: tabs.map((tab, index) => ({ ...tab, isActive: index === 1 })),
      });
    });
    expect(container.querySelector("input")?.value).toBe("");
    expect(useMavenStore.getStore(workspaceIds[1]).getState().settingsPath).toBe("");
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      browse.mockRestore();
      useWorkspaceTabsStore.setState({ projectTabs: previousTabs });
      for (const id of workspaceIds) workspaceRuntimeRegistry.removeWorkspace(id);
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
