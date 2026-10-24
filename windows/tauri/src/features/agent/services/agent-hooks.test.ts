import { describe, expect, spyOn, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/hooks-management-v1.json";
import * as platform from "@/platform/tauri-core";
import * as appData from "@/platform/app-data-directory";
import { manageHooks, parseHookLibrary, validHook, type AgentHook } from "./agent-hooks";

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
  test("validates command drafts, names, Agent choices and bounded integer timeouts", () => {
    const hook = fixture.hook as AgentHook;
    expect(validHook(hook)).toBe(true);
    for (const invalid of [{ name: "../escape" }, { command: " " }, { agents: [] }, { timeoutSeconds: 0 }, { timeoutSeconds: 1.5 }, { timeoutSeconds: 86401 }]) {
      expect(validHook({ ...hook, ...invalid })).toBe(false);
    }
    expect(validHook({ ...hook, timeoutSeconds: 86400 })).toBe(true);
  });
});
