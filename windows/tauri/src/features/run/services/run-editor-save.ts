export type RunEditorSaveStage = "prepare" | "write" | "reload";

type RunEditorSaveResult<Reloaded> =
  | { ok: true; reloaded: Reloaded }
  | { ok: false; stage: RunEditorSaveStage; error: unknown };

interface RunEditorSaveOperations<Prepared, Reloaded> {
  prepare: () => Promise<Prepared>;
  write: (prepared: Prepared) => Promise<void>;
  reload: () => Promise<Reloaded>;
}

export async function runEditorSaveWorkflow<Prepared, Reloaded>(
  operations: RunEditorSaveOperations<Prepared, Reloaded>,
): Promise<RunEditorSaveResult<Reloaded>> {
  let prepared: Prepared;
  try {
    prepared = await operations.prepare();
  } catch (error) {
    return { ok: false, stage: "prepare", error };
  }
  try {
    await operations.write(prepared);
  } catch (error) {
    return { ok: false, stage: "write", error };
  }
  try {
    return { ok: true, reloaded: await operations.reload() };
  } catch (error) {
    return { ok: false, stage: "reload", error };
  }
}

export function editorSaveFailureMessage(stage: RunEditorSaveStage, error: unknown): string {
  const detail = error instanceof Error ? error.message : String(error);
  switch (stage) {
    case "prepare":
      return `Could not prepare the run configuration: ${detail}`;
    case "write":
      return `Could not write the run configuration: ${detail}`;
    case "reload":
      return `Changes were saved, but Lithe could not reload them: ${detail}`;
  }
}
