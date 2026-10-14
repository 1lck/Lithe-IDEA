import { afterAll, expect, spyOn, test } from "bun:test";
import { act, useEffect, useState } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator } from "@/i18n/locale";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as dialog from "@/ui/dialog";
import * as panels from "./settings-panels";
import SettingsDialog from "./settings-dialog";
import { filterSettingsCategories } from "../lib/settings-navigation";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");

test("settings search finds shipped Chinese labels and English vocabulary on the correct page", () => {
  for (const language of ["en-US", "zh-CN"] as const) {
    const t = createTranslator(language);
    const matches = (query: string) => filterSettingsCategories(query, t).map(({ id }) => id);
    expect(matches("Minimap")).toContain("editor");
    expect(matches("AI Chat & Editing")).toContain("ai");
    expect(matches("Tools")).toContain("terminal");
    expect(matches(t("settings.editor.showMinimap"))).toContain("editor");
    expect(matches("字体连字")).toEqual(["editor"]);
    expect(matches("Font Ligatures")).toEqual(["editor"]);
    expect(matches("显示引用数量和 Git 作者")).toEqual(["editor"]);
    expect(matches("Show usages and Git author")).toEqual(["editor"]);
    expect(matches("自动补全")).toContain("lsp");
    expect(matches("语义高亮")).toContain("lsp");
    expect(matches("user.email")).toContain("git");
    expect(matches("settings.xml")).toContain("maven");
    expect(matches(t("settings.mac.editorTabs"))).toContain("editor");
    expect(matches(t("git.setup.email"))).toContain("git");
    expect(matches(t("settings.mac.autoSave"))).toContain("general");
    expect(matches(t("run.mavenJdkHome"))).toContain("project");
    expect(matches(t("settings.tabs.plugins"))).toContain("plugins");
    expect(matches("unknown-setting-zzzz")).toEqual([]);
  }
});

test("settings search excludes fields absent from the current panels", () => {
  for (const language of ["en-US", "zh-CN"] as const) {
    const t = createTranslator(language);
    for (const query of [
      "Sticky Scroll",
      "粘滞滚动",
      "UI Font Size",
      "界面字体大小",
      "Terminal Font Size",
      "Cursor Style",
    ]) {
      expect(filterSettingsCategories(query, t)).toEqual([]);
    }
  }
});

test("hierarchical navigation preserves drafts through empty search, automatic results and explicit navigation until Close", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const workspaceId = "settings-hierarchy-test";
  const livePages = new Set<string>();
  const frame = spyOn(dialog, "default").mockImplementation(({ children, footer }) => (
    <div>
      {children}
      {footer}
    </div>
  ));
  // Page/native operations are unrelated to navigation; the real dialog state and UI request store remain mounted.
  const panel = spyOn(panels, "SettingsPanel").mockImplementation(function DraftPage({ category }) {
    const [draft, setDraft] = useState("");
    useEffect(() => {
      livePages.add(category);
      return () => {
        livePages.delete(category);
      };
    }, [category]);
    return (
      <div data-probe-page={category}>
        <p>{category}</p>
        <input
          aria-label="Unsaved project path"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
      </div>
    );
  });
  const host = document.createElement("div");
  let root: Root | undefined;
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    const store = useUIState.getStore(workspaceId);
    store.setState({ settingsInitialTab: "general" });
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () =>
      mountedRoot.render(
        <WorkspaceStoreScopeContext.Provider value={workspaceId}>
          <LocaleProvider language="en-US">
            <SettingsDialog isOpen onClose={() => {}} />
          </LocaleProvider>
        </WorkspaceStoreScopeContext.Provider>,
      ),
    );
    const group = (id: string) =>
      host.querySelector<HTMLButtonElement>(`button[aria-controls="settings-group-${id}"]`)!;
    const currentPage = () =>
      host
        .querySelector("[data-settings-content]:not([hidden])")
        ?.getAttribute("data-settings-content");
    const search = host.querySelector<HTMLInputElement>('input[aria-label="Search settings"]')!;
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    const searchFor = async (query: string) =>
      act(async () => {
        setValue.call(search, query);
        search.dispatchEvent(new Event("input", { bubbles: true }));
      });
    expect(currentPage()).toBe("general");
    expect(group("tools").getAttribute("aria-expanded")).toBe("false");
    await searchFor("default shell");
    expect(currentPage()).toBe("terminal");
    expect(group("tools").getAttribute("aria-expanded")).toBe("true");
    expect(host.querySelector("[data-settings-breadcrumb]")?.textContent).toBe("ToolsTerminal");
    expect(host.querySelector('[data-settings-category="git"]')).toBeNull();

    await searchFor("unknown-setting-zzzz");
    expect(currentPage()).toBeUndefined();
    expect(host.querySelectorAll('[role="status"]')).toHaveLength(2);
    await act(async () => store.getState().openSettingsDialog("terminal"));
    expect(search.value).toBe("");
    expect(currentPage()).toBe("terminal");
    expect(group("tools").getAttribute("aria-expanded")).toBe("true");

    await act(async () => group("tools").click());
    expect(group("tools").getAttribute("aria-expanded")).toBe("false");
    await act(async () =>
      host.querySelector<HTMLButtonElement>('[data-settings-category="editor"]')!.click(),
    );
    await act(async () => store.getState().openSettingsDialog("terminal"));
    expect(currentPage()).toBe("terminal");
    expect(group("tools").getAttribute("aria-expanded")).toBe("true");
    await searchFor("Minimap");
    expect(currentPage()).toBe("editor");
    await act(async () =>
      search.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
    );
    expect(search.value).toBe("");
    expect(currentPage()).toBe("editor");

    await act(async () => store.getState().openSettingsDialog("project"));
    const projectPath = () =>
      host.querySelector<HTMLInputElement>(
        '[data-settings-content="project"] input[aria-label="Unsaved project path"]',
      )!;
    await act(async () => {
      setValue.call(projectPath(), "C:/toolchains/unsaved-jdk");
      projectPath().dispatchEvent(new Event("input", { bubbles: true }));
    });
    await searchFor("unknown-setting-zzzz");
    expect(currentPage()).toBeUndefined();
    await searchFor("");
    expect(currentPage()).toBe("project");
    expect(projectPath().value).toBe("C:/toolchains/unsaved-jdk");

    // A matching search used to unmount the project page, unlike an empty result.
    await searchFor("user.email");
    expect(currentPage()).toBe("git");
    await searchFor("");
    await act(async () => store.getState().openSettingsDialog("project"));
    expect(projectPath().value).toBe("C:/toolchains/unsaved-jdk");
    expect(host.querySelector('[data-probe-page="plugins"]')).toBeNull();

    await act(async () =>
      host.querySelector<HTMLButtonElement>('[data-settings-category="maven"]')!.click(),
    );
    const mavenPath = host.querySelector<HTMLInputElement>(
      '[data-settings-content="maven"] input[aria-label="Unsaved project path"]',
    )!;
    await act(async () => {
      setValue.call(mavenPath, "C:/toolchains/unsaved-maven");
      mavenPath.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await act(async () => store.getState().openSettingsDialog("project"));
    expect(projectPath().value).toBe("C:/toolchains/unsaved-jdk");
    await act(async () => store.getState().openSettingsDialog("maven"));
    expect(mavenPath.value).toBe("C:/toolchains/unsaved-maven");
    expect(host.querySelector('[data-settings-content="maven"] input')).toBe(mavenPath);

    const renderOpen = (isOpen: boolean) =>
      act(async () =>
        mountedRoot.render(
          <WorkspaceStoreScopeContext.Provider value={workspaceId}>
            <LocaleProvider language="en-US">
              <SettingsDialog isOpen={isOpen} onClose={() => {}} />
            </LocaleProvider>
          </WorkspaceStoreScopeContext.Provider>,
        ),
      );
    await renderOpen(false);
    expect(host.querySelector("[data-probe-page]")).toBeNull();
    expect(livePages.size).toBe(0);
    await renderOpen(true);
    expect(currentPage()).toBe("maven");
    expect(
      host.querySelector<HTMLInputElement>('[data-settings-content="maven"] input')!.value,
    ).toBe("");
    expect(host.querySelector('[data-probe-page="project"]')).toBeNull();
    expect([...livePages]).toEqual(["maven"]);
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      frame.mockRestore();
      panel.mockRestore();
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  }
});
