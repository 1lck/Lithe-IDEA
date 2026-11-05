import { invoke } from "@/platform/tauri-core";
import { isEditorContent, type PaneContent } from "@/features/panes/types/pane-content.types";

export type SaveBatchOutcome = "saved" | "failed" | "cancelled";

interface BatchDocument {
  id: string;
  dirty: boolean;
  readOnly: boolean;
  contentSynchronized: boolean;
}

export interface SaveBatchResult {
  status: "cancelled" | "failed" | "incomplete" | "saved";
  savedCount: number;
}

// Windows buffers are the source of truth for text, so a clean buffer never
// hides input that the model has not received.
function batchDocuments(buffers: readonly PaneContent[]): BatchDocument[] {
  return buffers.filter(isEditorContent).map((buffer) => ({
    id: buffer.id,
    dirty: buffer.isDirty,
    readOnly: !!buffer.readOnly,
    contentSynchronized: true,
  }));
}

/** Ids of the open documents a Save All writes (`document.planSaveBatch`). */
export async function planSaveBatch(buffers: readonly PaneContent[]): Promise<string[]> {
  const plan = await invoke<{ members: string[] }>("document.planSaveBatch", {
    documents: batchDocuments(buffers),
  });
  return plan.members;
}

/** Reduces member outcomes and the live buffers into one batch status (`document.reduceSaveBatch`). */
export async function reduceSaveBatch(
  members: readonly string[],
  outcomes: readonly SaveBatchOutcome[],
  liveBuffers: readonly PaneContent[],
): Promise<SaveBatchResult> {
  return invoke<SaveBatchResult>("document.reduceSaveBatch", {
    members,
    results: members.map((id, index) => ({ id, outcome: outcomes[index] })),
    documents: batchDocuments(liveBuffers),
  });
}
