import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { restoreAgentEdit } from "@/platform/agent-edit-restorer";
import { HostCommandError } from "@/platform/tauri-core";
import { Button } from "@/ui/button";
import { getPathIdentity } from "@/utils/path-helpers";
import { agentConnection, agentWorkspacePath } from "../stores/agent-connection-service";
import { agentFileChanges, canRevertAgentChange, type AgentFileChange } from "../services/agent-edit-review";
import type { AgentConversation, AgentToolLocation } from "../types/agent.types";

export function AgentEditReview({ conversation, sessionID, onOpenLocation }: {
  conversation: AgentConversation; sessionID: string; onOpenLocation: (location: AgentToolLocation) => void;
}) {
  const { t } = useTranslation();
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);
  const changes = agentFileChanges(conversation.messages, conversation.reviewedEdits);
  if (changes.length === 0) return null;
  const active = conversation.isResponding || conversation.isLoading || busy !== null;
  const acknowledge = (change: AgentFileChange) => agentConnection().acknowledgeEdits(sessionID, change.path, change.versions);
  const revert = async (change: AgentFileChange) => {
    const workspace = agentWorkspacePath();
    if (!workspace || active || inFlight.current) return;
    inFlight.current = true;
    setBusy(change.path); setError(null);
    try {
      await restoreAgentEdit(workspace, change, (path) => useBufferStore.getState().buffers.some((buffer) => {
        if (buffer.type !== "editor" || !buffer.isDirty || getPathIdentity(buffer.path) !== getPathIdentity(path)) return false;
        // Moving a document to recovery/recycle storage emits a watcher conflict
        // before the native revert finishes. That lifecycle flag is not a user
        // edit; keep blocking when the user changed the conflicted text itself.
        return buffer.documentLifecycle?.status !== "conflict" || buffer.content !== buffer.savedContent;
      }));
      if (mounted.current && agentWorkspacePath() === workspace) acknowledge(change);
    } catch (failure) {
      const key = failure instanceof Error ? failure.message : "";
      const details = failure instanceof HostCommandError && typeof failure.details === "string" ? failure.details : "";
      const recovery = details.split("; recover the document from ")[1];
      if (mounted.current) setError(recovery ? t("agent.edits.recoveryRequired", { path: recovery }) : key.startsWith("agent.edits.") ? t(key) : t("agent.edits.failed"));
    } finally {
      inFlight.current = false;
      if (mounted.current) setBusy(null);
    }
  };
  return <details className="mx-3 mb-2 max-h-72 shrink-0 overflow-auto rounded border border-border p-2 ui-text-caption">
    <summary>{t("agent.edits.title", { count: changes.length })}</summary>
    {changes.map((change) => <div key={change.path} className="border-border border-t py-2">
      <div className="flex items-center gap-2">
        <button type="button" className="min-w-0 flex-1 truncate text-left hover:underline" title={change.path}
          onClick={() => onOpenLocation({ path: change.path, line: null })}>{change.path}</button>
        <Button size="xs" variant="ghost" disabled={active || change.pending} onClick={() => acknowledge(change)}>{t("agent.edits.keep")}</Button>
        <Button size="xs" variant="ghost" disabled={active || !canRevertAgentChange(change)} onClick={() => void revert(change)}>{t("agent.edits.revert")}</Button>
      </div>
      {change.diffs.map((diff, index) => <details key={index}><summary>{t("agent.edits.diff")}</summary>
        <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all font-mono">{`---\n${diff.oldText ?? ""}\n+++\n${diff.newText}`}</pre>
      </details>)}
      {change.incomplete ? <span className="text-subtle-foreground">{t("agent.edits.incomplete")}</span> : null}
    </div>)}
    {error ? <div role="alert" className="text-warning">{error}</div> : null}
  </details>;
}
