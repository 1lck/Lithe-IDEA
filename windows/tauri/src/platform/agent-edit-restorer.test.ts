import { beforeEach, describe, expect, mock, test } from "bun:test";

/**
 * Host stubs for the rollback flow. Core planning is stubbed by `plan`; the
 * shared fixture proves the planner itself in Rust and through the macOS bridge.
 */
let plan: unknown = { action: "none" };
let disk: { content: string; encoding: string; identity: string } | null = { content: "new", encoding: "UTF-8", identity: "id-1" };
const calls: [string, unknown][] = [];
const invoke = mock(async (command: string, args?: unknown): Promise<unknown> => {
  calls.push([command, args]);
  if (command === "resolve_agent_document_path") return "C:/work/sample.txt";
  if (command === "agent.edits.reversePlan") return plan;
  if (command === "save_agent_document") return { status: "saved" };
  if (command === "trash_agent_document") return null;
  throw new Error(`Unexpected command: ${command}`);
});
const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));
const documentFilesModule = await import("@/platform/document-files");
mock.module("@/platform/document-files", () => ({ ...documentFilesModule, readDocumentFileDetails: async () => disk }));
const { restoreAgentEdit } = await import("./agent-edit-restorer");

const change = {
  path: "sample.txt", versions: [], pending: false, missingEvidence: false, incomplete: false,
  diffs: [{ path: "sample.txt", oldText: "old", newText: "new", operation: null, incomplete: false, revertible: true, toolKind: "edit" }],
};
const commands = () => calls.map(([command]) => command);

describe("Agent edit restorer", () => {
  beforeEach(() => {
    calls.length = 0;
    disk = { content: "new", encoding: "UTF-8", identity: "id-1" };
  });
  test("sends evidence and disk text to Core and writes the planned text", async () => {
    plan = { action: "write", text: "old" };
    await restoreAgentEdit("C:/work", change, () => false);
    expect(calls.find(([command]) => command === "agent.edits.reversePlan")?.[1]).toEqual({
      diffs: [{ oldText: "old", newText: "new", operation: null, toolKind: "edit", truncated: false }],
      pending: false, missingEvidence: false, disk: "new",
    });
    expect(calls.find(([command]) => command === "save_agent_document")?.[1]).toMatchObject({ content: "old", expectedContent: "new", expectedIdentity: "id-1" });
  });
  test("trashes a created file only through the guarded native command", async () => {
    plan = { action: "trash" };
    await restoreAgentEdit("C:/work", change, () => false);
    expect(commands()).toContain("trash_agent_document");
    expect(commands()).not.toContain("save_agent_document");
  });
  test("a plan without changes writes nothing", async () => {
    plan = { action: "none" };
    await restoreAgentEdit("C:/work", change, () => false);
    expect(commands()).not.toContain("save_agent_document");
    expect(commands()).not.toContain("trash_agent_document");
  });
  test("conflicts surface the stable localized key and never write", async () => {
    for (const [reason, key] of [["changed", "agent.edits.changed"], ["incomplete", "agent.edits.incomplete"]]) {
      calls.length = 0;
      plan = { action: "conflict", reason };
      await expect(restoreAgentEdit("C:/work", change, () => false)).rejects.toThrow(key);
      expect(commands()).not.toContain("save_agent_document");
    }
  });
});
