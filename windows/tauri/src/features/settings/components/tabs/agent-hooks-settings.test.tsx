import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import * as service from "@/features/agent/services/agent-hooks";
import * as dialog from "@/ui/dialog";
import * as switchControl from "@/ui/switch";
import fixture from "../../../../../../../shared/fixtures/agent/hooks-management-v1.json";
import { AgentHooksSettings } from "./agent-hooks-settings";

test.each([
  { language: "en-US" as const, searchLabel: "Search Hooks", reloadLabel: "Reload from disk", noMatches: "No matching Hooks.", empty: "No Hooks yet." },
  { language: "zh-CN" as const, searchLabel: "搜索 Hook", reloadLabel: "从磁盘重新加载", noMatches: "没有匹配的 Hook。", empty: "还没有 Hook。" },
])("Hook search reports no matches and restores results ($language)", async ({ language, searchLabel, reloadLabel, noMatches, empty }) => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  const root = createRoot(container);
  let library = service.parseHookLibrary(fixture.library)!;
  const managed = spyOn(service, "manageHooks").mockImplementation(async () => library);
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    await act(async () => root.render(<LocaleProvider language={language}><AgentHooksSettings /></LocaleProvider>));
    const search = container.querySelector<HTMLInputElement>(`input[aria-label="${searchLabel}"]`)!;
    expect(search).not.toBeNull();
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    const searchFor = async (query: string) => act(async () => {
      setValue.call(search, query);
      search.dispatchEvent(new Event("input", { bubbles: true }));
    });
    for (const query of ["NOTIFY", "结束时", "PRINTF DONE"]) {
      await searchFor(query);
      expect(container.querySelector("strong")?.textContent).toBe("notify");
      expect(container.querySelector('[role="status"]')).toBeNull();
    }
    await searchFor("unmatched-hook");
    expect(container.querySelector("strong")).toBeNull();
    expect(container.querySelector('[role="status"]')?.textContent).toBe(noMatches);
    expect(container.textContent).not.toContain(empty);
    await searchFor("");
    expect(container.querySelector("strong")?.textContent).toBe("notify");
    expect(container.querySelector('[role="status"]')).toBeNull();
    expect(managed).toHaveBeenCalledTimes(1);
    library = { ...library, hooks: [] };
    const reload = Array.from(container.querySelectorAll("button")).find(button => button.textContent === reloadLabel)!;
    expect(reload).toBeDefined();
    await act(async () => reload.click());
    expect(container.querySelector('[role="status"]')?.textContent).toBe(empty);
    await searchFor("unmatched-hook");
    expect(container.querySelector('[role="status"]')?.textContent).toBe(noMatches);
    expect(managed.mock.calls.every(([action]) => action === "read")).toBe(true);
  } finally {
    try { await act(async () => root.unmount()); }
    finally {
      managed.mockRestore();
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});

test("Hook editor retains a failed draft, retries with its guard and updates native switches", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  const root = createRoot(container);
  const library = service.parseHookLibrary(fixture.library)!;
  const writes: service.AgentHook[] = [];
  const revisions: string[] = [];
  let fails = true;
  const managed = spyOn(service, "manageHooks").mockImplementation(async (action, before, hook) => {
    if (action === "read") return library;
    if (action === "save") {
      expect(before).not.toBeUndefined();
      expect(hook).not.toBeUndefined();
      if (fails) throw new Error("Fixture conflict");
      writes.push(hook!); revisions.push(before!.revision);
      return { ...library, revision: `saved-${writes.length}`, hooks: [{ ...hook!, configuredAgents: hook!.enabled ? hook!.agents : [], needsSync: false }] };
    }
    if (action === "remove") return { ...library, revision: "removed", hooks: [] };
    return library;
  });
  const frame = spyOn(dialog, "default").mockImplementation(({ children, footer, title }) => <div role="dialog"><h2>{title}</h2>{children}{footer}</div>);
  const confirms = spyOn(dialog, "showConfirmDialog").mockResolvedValue(true);
  const toggle = spyOn(switchControl, "default").mockImplementation(({ checked, onChange, disabled, "aria-label": label }) => (
    <button aria-label={label} aria-checked={checked} disabled={disabled} onClick={() => onChange(!checked)}>native-switch</button>
  ));
  const button = (title: string) => {
    const found = Array.from(container.querySelectorAll("button")).find(element => element.textContent === title);
    expect(found).toBeDefined();
    return found!;
  };
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    await act(async () => root.render(<LocaleProvider language="en-US"><AgentHooksSettings /></LocaleProvider>));
    expect(container.textContent).toContain("notify");
    expect(container.textContent).toContain("Sync needed");
    await act(async () => button("Edit").click());
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    expect(container.textContent).toContain("Edit Hook");
    expect(container.querySelector<HTMLTextAreaElement>('textarea[aria-label="Description"]')?.value).toBe(fixture.hook.description);
    await act(async () => button("Codex").click());
    await act(async () => button("Claude Code").click());
    expect(button("Save Hook").disabled).toBe(true);
    expect(writes).toHaveLength(0);
    await act(async () => button("All").click());
    expect(button("Codex").getAttribute("aria-pressed")).toBe("true");
    expect(button("Claude Code").getAttribute("aria-pressed")).toBe("true");
    await act(async () => button("Save Hook").click());
    expect(container.textContent).toContain("Fixture conflict");
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    expect(container.querySelector<HTMLTextAreaElement>('textarea[aria-label="Command"]')?.value).toBe("printf done");
    fails = false;
    await act(async () => button("Save Hook").click());
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(writes[0]?.id).toBe(fixture.hook.id);
    expect(revisions[0]).toBe(fixture.library.revision);
    await act(async () => button("native-switch").click());
    expect(writes[1]?.enabled).toBe(false);
    expect(revisions[1]).toBe("saved-1");
    await act(async () => button("Delete").click());
    expect(confirms).toHaveBeenCalledTimes(1);
    expect(container.textContent).toContain("No Hooks yet.");
    await act(async () => button("Add Hook").click());
    expect(container.textContent).toContain("New Hook");
    expect(container.querySelector<HTMLInputElement>('input[aria-label="Name"]')?.value).toBe("");
    await act(async () => button("Cancel").click());
    expect(container.querySelector('[role="dialog"]')).toBeNull();
  } finally {
    try { await act(async () => root.unmount()); }
    finally {
      toggle.mockRestore(); confirms.mockRestore(); frame.mockRestore(); managed.mockRestore();
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
