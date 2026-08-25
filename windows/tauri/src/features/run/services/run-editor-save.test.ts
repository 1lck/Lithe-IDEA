import { describe, expect, mock, test } from "bun:test";
import { editorSaveFailureMessage, runEditorSaveWorkflow } from "./run-editor-save";

describe("run configuration editor saving", () => {
  test("returns the reloaded snapshot only after every stage succeeds", async () => {
    const calls: string[] = [];
    const result = await runEditorSaveWorkflow({
      prepare: async () => {
        calls.push("prepare");
        return { localDocument: "{}" };
      },
      write: async () => {
        calls.push("write");
      },
      reload: async () => {
        calls.push("reload");
        return { status: "ready" as const };
      },
    });

    expect(result).toEqual({ ok: true, reloaded: { status: "ready" } });
    expect(calls).toEqual(["prepare", "write", "reload"]);
  });

  test("identifies preparation failures before writing", async () => {
    const write = mock(async () => undefined);
    const result = await runEditorSaveWorkflow({
      prepare: async () => {
        throw new Error("Injected Core failure.");
      },
      write,
      reload: async () => ({ status: "ready" }),
    });

    expect(result).toEqual(expect.objectContaining({ ok: false, stage: "prepare" }));
    expect(write).not.toHaveBeenCalled();
  });

  test("identifies document write failures without reloading", async () => {
    const reload = mock(async () => ({ status: "ready" }));
    const result = await runEditorSaveWorkflow({
      prepare: async () => ({ localDocument: "{}" }),
      write: async () => {
        throw new Error("Injected write failure.");
      },
      reload,
    });

    expect(result).toEqual(expect.objectContaining({ ok: false, stage: "write" }));
    expect(reload).not.toHaveBeenCalled();
  });

  test("reports that documents were saved when reload fails", async () => {
    const result = await runEditorSaveWorkflow({
      prepare: async () => ({ localDocument: "{}" }),
      write: async () => undefined,
      reload: async () => {
        throw new Error("Injected reload failure.");
      },
    });

    expect(result).toEqual(expect.objectContaining({ ok: false, stage: "reload" }));
    if (result.ok) throw new Error("Expected the reload stage to fail.");
    expect(editorSaveFailureMessage(result.stage, result.error)).toContain(
      "Changes were saved, but Lithe could not reload them",
    );
  });
});
