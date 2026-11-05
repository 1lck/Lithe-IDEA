import { describe, expect, spyOn, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/hooks-management-v1.json";
import draftFixture from "../../../../../../shared/fixtures/agent/hook-draft-validation-v1.json";
import * as platform from "@/platform/tauri-core";
import * as appData from "@/platform/app-data-directory";
import { hookDraftIssueKey, manageHooks, parseHookLibrary, validateHookDraft, type AgentHook } from "./agent-hooks";
import { createTranslator } from "@/i18n/locale";

describe("native Agent Hook management contract", () => {
  test("reload omits mutation guards while save preserves the reviewed snapshots", async () => {
    const directory = spyOn(appData, "resolveAppDataDirectory").mockResolvedValue("C:/fixture/Lithe");
    const invoked = spyOn(platform, "invoke").mockResolvedValue(fixture.library);
    try {
      const library = parseHookLibrary(fixture.library)!;
      expect(await manageHooks("read", library)).toEqual(library);
      expect(invoked).toHaveBeenLastCalledWith("agent.hooks", {
        dataDirectory: "C:/fixture/Lithe/AgentHooks", action: "read",
      });
      await manageHooks("save", library, fixture.hook as AgentHook);
      expect(invoked).toHaveBeenLastCalledWith("agent.hooks", {
        dataDirectory: "C:/fixture/Lithe/AgentHooks", action: "save",
        expectedRevision: library.revision,
        files: library.targets.flatMap(target => target.file ? [target.file] : []),
        hook: fixture.hook,
      });
    } finally { invoked.mockRestore(); directory.mockRestore(); }
  });
  test("reads the shared partial-success fixture without treating placement as execution", () => {
    const library = parseHookLibrary(fixture.library);
    expect(library?.hooks[0]?.configuredAgents).toEqual(["codex-acp"]);
    expect(library?.hooks[0]?.needsSync).toBe(true);
    expect(library?.targets[1]?.file).toBeNull();
  });
  test("rejects invalid response fields and invalid event names", () => {
    expect(parseHookLibrary({ ...fixture.library, targets: [{}] })).toBeNull();
    expect(parseHookLibrary({ ...fixture.library, hooks: [{ ...fixture.library.hooks[0], event: "unknown" }] })).toBeNull();
    expect(parseHookLibrary({ ...fixture.library, hooks: [{ ...fixture.library.hooks[0], timeoutSeconds: -1 }] })).toBeNull();
  });
  test("draft validation sends the raw timeout text and library names to Core and accepts its verdict", async () => {
    const library = parseHookLibrary(fixture.library)!;
    for (const item of draftFixture.cases) {
      const invoked = spyOn(platform, "invoke").mockResolvedValue(item.expected);
      try {
        const { timeoutText, ...fields } = item.request.hook;
        const hook = { ...fields, timeoutSeconds: null, enabled: true, pendingRemoval: false } as AgentHook;
        expect(await validateHookDraft(hook, timeoutText, library)).toEqual(item.expected as never);
        expect(invoked).toHaveBeenLastCalledWith("agent.hooks.validateDraft", {
          hook: item.request.hook,
          existingHooks: library.hooks.map(entry => ({ id: entry.id, name: entry.name })),
        });
      } finally { invoked.mockRestore(); }
    }
    const invalid = spyOn(platform, "invoke").mockResolvedValue({ valid: "yes" });
    try {
      await expect(validateHookDraft(fixture.hook as AgentHook, "", library)).rejects.toThrow("not recognised");
    } finally { invalid.mockRestore(); }
  });
  test("every Core draft issue in the shared fixture has English and Chinese text", () => {
    const issues = draftFixture.cases.flatMap(item => item.expected.issues);
    for (const language of ["en-US", "zh-CN"] as const) {
      const t = createTranslator(language);
      for (const issue of issues) expect(t(hookDraftIssueKey(issue))).not.toBe(hookDraftIssueKey(issue));
    }
  });
});
