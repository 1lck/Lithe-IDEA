import { invoke } from "./tauri-core";
import { readDocumentFileDetails, type DocumentSaveOutcome } from "./document-files";
import { agentReversePlanRequest, type AgentFileChange, type AgentReversePlan } from "@/features/agent/services/agent-edit-review";

export async function resolveAgentEditPath(workspace: string, path: string): Promise<string> {
  return invoke("resolve_agent_document_path", { workspace, path });
}

/** Encoding and expected byte identity come from the native document adapter. */
export async function restoreAgentEdit(workspace: string, change: AgentFileChange, isDirty: (path: string) => boolean): Promise<void> {
  const path = await resolveAgentEditPath(workspace, change.path);
  if (isDirty(path)) throw new Error("agent.edits.dirty");
  const disk = await readDocumentFileDetails(path);
  // Core owns matching, line endings, deletion and conflict rules.
  const plan = await invoke<AgentReversePlan>("agent.edits.reversePlan", agentReversePlanRequest(change, disk?.content ?? null));
  if (plan.action === "conflict") throw new Error(plan.reason === "incomplete" ? "agent.edits.incomplete" : "agent.edits.changed");
  if (plan.action === "none") return;
  if (isDirty(path)) throw new Error("agent.edits.dirty");
  // Resolve again after asynchronous reads; parent links must still point inside this workspace.
  if (await resolveAgentEditPath(workspace, change.path) !== path || isDirty(path)) throw new Error("agent.edits.changed");
  if (plan.action === "trash") {
    if (!disk) throw new Error("agent.edits.changed");
    await invoke("trash_agent_document", { workspace, path, expectedIdentity: disk.identity });
  } else {
    const result = await invoke<DocumentSaveOutcome>("save_agent_document", { workspace, path, content: plan.text,
      expectedContent: disk?.content ?? null, encoding: disk?.encoding ?? "UTF-8", expectedIdentity: disk?.identity });
    if (result.status !== "saved") throw new Error("agent.edits.changed");
  }
}
