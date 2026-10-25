import { toast } from "sonner";
import isEqual from "fast-deep-equal";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { isAgentLocalFile } from "@/platform/agent-local-files";
import type { MenuItem } from "@/ui/dropdown";
import { openAgentConversationInEditor } from "../actions/agent-conversation-placement-actions";
import { openAgentToolWindow } from "../actions/agent-tool-window-actions";
import { validatedAttachmentUris } from "../services/agent-file-attachments";
import { agentConnection, cachedAgentSessions, openAgentConnection } from "../stores/agent-connection-service";
import { agentDraftKey, useAgentSurfaceStore } from "../stores/agent-surface.store";
import { configuredAgentIDs, selectAgentConfiguration } from "../types/agent-settings.types";
import { addFileReferences, AgentFileReferenceLimitError } from "../types/agent.types";

const AGENT_LABELS: Record<string, string> = { "codex-acp": "Codex", "claude-acp": "Claude" };

/** Build from cached state only. Revalidate the captured workspace at execution. */
export function useAgentFileContextMenu() {
  const { t } = useTranslation();
  return (paths: string[]): MenuItem[] => {
    const workspace = useFileSystemStore.getState().rootFolderPath;
    if (!workspace || paths.length === 0 || paths.some((path) => path.includes("://"))) return [];
    const settings = useSettingsStore.getState().settings.agentPanel;
    const isCurrent = () => useFileSystemStore.getState().rootFolderPath === workspace &&
      useSettingsStore.getState().settings.agentPanel === settings;
    const ids = settings.enabled ? configuredAgentIDs(settings) : [];
    const showSettings = () => {
      if (!isCurrent()) { toast.error(t("agent.context.stale")); return; }
      openAgentToolWindow();
      useAgentSurfaceStore.getState().actions.navigate(settings.agentId, null, "toolWindow", "settings");
    };
    const attach = async (agentID: string, sessionID: string | null) => {
      try {
        const uris = await validatedAttachmentUris(paths, isAgentLocalFile, isCurrent);
        const next = selectAgentConfiguration(settings, agentID);
        const connection = agentConnection();
        if (agentID !== settings.agentId && (connection.getSnapshot().isCreatingSession || Object.values(connection.getSnapshot().conversations).some((view) =>
          view.isResponding || view.isLoading || view.pendingConfigToken !== null || view.pendingPermissions.length > 0))) {
          throw new Error("agent.context.busy");
        }
        if (sessionID !== null && !cachedAgentSessions(workspace, next).some((entry) => entry.id === sessionID)) {
          throw new Error("agent.context.stale");
        }
        const key = agentDraftKey(agentID, sessionID);
        // Check the destination limit before switching Agent or selecting a session.
        addFileReferences(useAgentSurfaceStore.getState().drafts[key]?.files ?? [], uris);
        let expected = settings;
        if (next !== settings) {
          const committed = await useSettingsStore.getState().actions.commitAgentProvider(settings, next);
          expected = useSettingsStore.getState().settings.agentPanel;
          if (!isEqual(expected, committed)) throw new Error("agent.context.stale");
        }
        if (useFileSystemStore.getState().rootFolderPath !== workspace ||
          useSettingsStore.getState().settings.agentPanel !== expected) throw new Error("agent.context.stale");
        const connected = await openAgentConnection(workspace, expected);
        if (useFileSystemStore.getState().rootFolderPath !== workspace ||
          connected === null || !isEqual(useSettingsStore.getState().settings.agentPanel, connected)) throw new Error("agent.context.stale");
        // Re-read the draft after asynchronous launch so concurrent typing is kept.
        const actions = useAgentSurfaceStore.getState().actions;
        actions.appendDraftFiles(key, uris);
        if (sessionID === null) connection.startNewConversation();
        else connection.selectSession(sessionID);
        const editor = sessionID !== null && useBufferStore.getState().buffers.some((buffer) =>
          buffer.type === "agentConversation" && buffer.agentId === agentID && buffer.sessionId === sessionID);
        if (editor && sessionID !== null) openAgentConversationInEditor(sessionID, agentID);
        else openAgentToolWindow();
        actions.navigate(agentID, sessionID, editor ? "editor" : "toolWindow");
        const dirty = useBufferStore.getState().buffers.some((buffer) =>
          buffer.type === "editor" && buffer.isDirty && paths.includes(buffer.path));
        if (dirty) toast.warning(t("agent.context.dirty"));
      } catch (error) {
        toast.error(error instanceof AgentFileReferenceLimitError ? t("agent.composer.fileLimit", { count: error.limit }) :
          error instanceof Error && error.message.startsWith("agent.context.") ? t(error.message) : String(error));
      }
    };
    if (ids.length === 0) return [{ id: "agent-setup", label: t("agent.context.setup"), onClick: showSettings }];
    const selected = agentConnection().getSnapshot().selectedSessionID;
    const destinations: MenuItem[] = ids.map((id) => {
      const candidate = selectAgentConfiguration(settings, id);
      return { id: `agent-${id}`, label: AGENT_LABELS[id] ?? id, onClick: () => {}, children: [
        { id: `agent-${id}-new`, label: t("agent.context.new"), onClick: () => attach(id, null) },
        ...cachedAgentSessions(workspace, candidate).map((session) => ({
          id: `agent-${id}-${session.id}`,
          label: `${id === settings.agentId && selected === session.id ? "✓ " : ""}${session.title ?? t("agent.tabs.untitled")} · ${session.id.slice(0, 8)}`,
          onClick: () => attach(id, session.id),
        })),
      ] };
    });
    const quick: MenuItem[] = ids.includes(settings.agentId) ? [{
      id: "agent-current", label: `${AGENT_LABELS[settings.agentId] ?? settings.agentId} · ${t("agent.context.current")}`,
      onClick: () => attach(settings.agentId, selected),
    }] : [];
    return [{ id: "agent-attach", label: t("agent.context.attach"), onClick: () => {}, children: [...quick, ...destinations] }];
  };
}
