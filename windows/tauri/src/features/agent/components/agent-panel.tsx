import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useShallow } from "zustand/react/shallow";
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import {
  ArrowSquareOutIcon,
  CaretDoubleRightIcon,
  CaretLeftIcon,
  ClockCounterClockwiseIcon,
  GearIcon,
  MagnifyingGlassIcon,
  PlusIcon,
  SidebarSimpleIcon,
  SparkleIcon,
  SquareSplitHorizontalIcon,
  UserCircleIcon,
  WarningIcon,
  XIcon,
} from "@/ui/icons";
import { cn } from "@/utils/cn";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { joinPath } from "@/utils/path-helpers";
import { openAgentConversationInEditor } from "../actions/agent-conversation-placement-actions";
import { useAgentManagement } from "../hooks/use-agent-management";
import { useAgentSnapshot } from "../hooks/use-agent-connection";
import { useAgentHistory } from "../hooks/use-agent-history";
import { useAgentConnectionOwnership } from "../hooks/use-agent-connection-ownership";
import { AgentHistoryExportError, saveHistoryMarkdown } from "../services/agent-history-save";
import { historyMarkdown, type AgentHistoryDocument } from "../services/agent-history-export";
import { historyTitle } from "../services/agent-history-view";
import { provisionalTabTitle } from "../services/agent-transcript-items";
import { editorAgentSessionIDs, resolveAgentEditorBinding } from "../services/agent-editor-binding";
import {
  agentConnection,
  agentDataDirectory,
  closeAgentConnection,
  openAgentConnection,
} from "../stores/agent-connection-service";
import {
  EMPTY_AGENT_DRAFT,
  NEW_AGENT_DRAFT_KEY,
  useAgentSurfaceStore,
} from "../stores/agent-surface.store";
import { CODEX_AGENT_ID, CLAUDE_AGENT_ID } from "../types/agent-settings.types";
import {
  currentPermission,
  type AgentConversation,
  type AgentFileReference,
  type AgentToolLocation,
} from "../types/agent.types";
import { AgentComposer } from "./agent-composer";
import { AgentConversationTabs } from "./agent-conversation-tabs";
import { AgentHistoryList } from "./agent-history-list";
import {
  AgentEmptyState,
  AgentInlineNotice,
  AgentPanelHeader,
  AgentToolbarButton,
} from "./agent-panel-parts";
import { AgentSettingsSection } from "./agent-settings-section";
import { AgentHero, AgentActivitySummaryBar, AgentTranscript } from "./agent-transcript";
import { AgentContextUsageView } from "./agent-usage-panel";

/** How often a visible subscription panel asks the host for fresh quota. */
const QUOTA_REFRESH_MILLISECONDS = 60_000;

/** Display names of the built-in agents, as the macOS agent options show them. */
const AGENT_NAMES: Record<string, string> = {
  [CODEX_AGENT_ID]: "Codex",
  [CLAUDE_AGENT_ID]: "Claude",
};

type AgentPanelPage = "conversation" | "settings" | "history";

export type AgentPanelPlacement = "toolWindow" | "editor";

interface AgentPanelProps {
  onClose: () => void;
  /**
   * The tool window keeps history visible while an editor tab owns the
   * conversation; the editor surface is the centered conversation itself.
   */
  placement?: AgentPanelPlacement;
  isActive?: boolean;
  /** Session bound to the editor tab. The tool window follows the connection. */
  sessionID?: string | null;
  /** Agent that owns the session bound to the editor tab. */
  agentId?: string | null;
  onMoveToToolWindow?: () => void;
  onTitleChange?: (title: string) => void;
}

/**
 * The Agent sidebar, matching `AgentConversationView` on macOS.
 *
 * Settings and history replace the conversation as whole pages, the
 * conversation always shows its full layout, and sending validates the setup
 * instead of hiding the composer. No Agent process starts until the panel is
 * enabled and the project's adapter is configured.
 */
export function AgentPanel({
  onClose,
  placement = "toolWindow",
  isActive = true,
  sessionID = null,
  agentId = null,
  onMoveToToolWindow,
  onTitleChange,
}: AgentPanelProps) {
  const { t } = useTranslation();
  const isEditorPlacement = placement === "editor";
  const detailsOpen = useAgentSurfaceStore((state) => state.detailsOpen);
  const surfaceActions = useAgentSurfaceStore.use.actions();
  const snapshot = useAgentSnapshot();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath ?? null);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const settings = useSettingsStore((state) => state.settings.agentPanel);
  // Buffer ownership survives cached workspace hiding and connection resets.
  const editorSessionIDs = useBufferStore(
    useShallow((state) => editorAgentSessionIDs(state.buffers, settings.agentId)),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const boundAgentID = isEditorPlacement ? (agentId === "" ? null : agentId) : null;
  const history = useAgentHistory(rootFolderPath, boundAgentID ?? settings.agentId);
  const [dataDirectory, setDataDirectory] = useState<string | null>(null);
  const [page, setPage] = useState<AgentPanelPage>("conversation");
  const management = useAgentManagement(dataDirectory, page === "settings" || !settings.enabled);
  const [showsSearch, setShowsSearch] = useState(false);
  const [searchText, setSearchText] = useState("");
  const [showsTabs, setShowsTabs] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const status = snapshot.connectionState.status;
  const { sessionID: surfaceSessionID, isForeignAgent } = resolveAgentEditorBinding({
    isEditor: isEditorPlacement,
    boundSessionID: sessionID,
    boundAgentID,
    activeAgentID: settings.agentId,
    selectedSessionID: snapshot.selectedSessionID,
  });
  const selected = surfaceSessionID;
  const conversation = selected === null ? null : (snapshot.conversations[selected] ?? null);

  // Drafts belong to the conversation key, not to whichever surface happens
  // to be mounted. Moving the conversation therefore keeps unsent text and
  // attachments, and two surfaces never fight over the same composer.
  const draftKey = selected ?? NEW_AGENT_DRAFT_KEY;
  const draftEntry = useAgentSurfaceStore((state) => state.drafts[draftKey]);
  const draft = draftEntry?.text ?? EMPTY_AGENT_DRAFT.text;
  const files = draftEntry?.files ?? EMPTY_AGENT_DRAFT.files;
  const setDraft = useCallback(
    (value: string) => surfaceActions.setDraftText(draftKey, value),
    [draftKey, surfaceActions],
  );
  const setFiles = useCallback(
    (next: AgentFileReference[]) => surfaceActions.setDraftFiles(draftKey, next),
    [draftKey, surfaceActions],
  );

  // A session can be created while the user is already typing under the
  // "new conversation" key. Move that draft onto the real session instead of
  // making the text disappear when the key changes.
  const previousSelected = useRef<string | null>(selected);
  useEffect(() => {
    const previous = previousSelected.current;
    previousSelected.current = selected;
    if (previous !== null || selected === null) return;
    const pending = useAgentSurfaceStore.getState().drafts[NEW_AGENT_DRAFT_KEY];
    if (pending === undefined) return;
    surfaceActions.setDraft(selected, pending);
    surfaceActions.clearDraft(NEW_AGENT_DRAFT_KEY);
  }, [selected, surfaceActions]);
  const activeAgentId = boundAgentID ?? settings.agentId;
  const agentName = AGENT_NAMES[activeAgentId] ?? snapshot.agentName;
  const isConfigured = settings.enabled && rootFolderPath !== null;
  // macOS refuses to change a provider while a connection could lose work.
  const canChangeAuthentication =
    snapshot.connectionState.status !== "connecting" &&
    !snapshot.isCreatingSession &&
    !Object.values(snapshot.conversations).some(
      (conversation) =>
        conversation.isResponding ||
        conversation.isLoading ||
        conversation.pendingConfigToken !== null ||
        conversation.pendingPermissions.length > 0,
    );

  const { ownsConnection: connectionMatchesWorkspace, claim } = useAgentConnectionOwnership({
    isActive,
    workspacePath: rootFolderPath,
    settings,
  });

  const reconnect = useCallback(() => {
    // Read the store at call time: a settings edit is committed before the
    // reconnect request, while this render's `settings` is still the old value.
    const current = useSettingsStore.getState().settings.agentPanel;
    if (rootFolderPath === null) return;
    void closeAgentConnection()
      .then(() => (current.enabled ? openAgentConnection(rootFolderPath, current) : undefined))
      .then(() => claim(rootFolderPath, current))
      .catch(() => undefined);
  }, [claim, rootFolderPath]);

  const switchToBoundAgent = useCallback(() => {
    if (boundAgentID === null) return;
    const current = useSettingsStore.getState().settings.agentPanel;
    void updateSetting("agentPanel", { ...current, agentId: boundAgentID });
  }, [boundAgentID, updateSetting]);

  useEffect(() => {
    void agentDataDirectory()
      .then(setDataDirectory)
      .catch(() => setDataDirectory(null));
  }, []);

  useEffect(() => {
    if (!connectionMatchesWorkspace || status !== "ready" || isForeignAgent) return;
    // An editor tab waits for its bound session instead of creating a fresh
    // empty conversation before that session is selected.
    if (isEditorPlacement && sessionID !== null && snapshot.selectedSessionID !== sessionID) return;
    agentConnection().prepareConversation();
  }, [
    connectionMatchesWorkspace,
    isEditorPlacement,
    isForeignAgent,
    sessionID,
    snapshot.selectedSessionID,
    status,
  ]);

  // An editor tab is bound to one session. Only the visible tab may select it,
  // otherwise every hidden tab would keep stealing the shared connection.
  useEffect(() => {
    if (
      isForeignAgent ||
      !isEditorPlacement ||
      !connectionMatchesWorkspace ||
      sessionID === null ||
      status !== "ready"
    )
      return;
    if (snapshot.selectedSessionID === sessionID) return;
    agentConnection().selectSession(sessionID);
  }, [
    connectionMatchesWorkspace,
    isEditorPlacement,
    isForeignAgent,
    sessionID,
    snapshot.selectedSessionID,
    status,
  ]);

  // Quota polls only while the conversation itself is visible, as on macOS.
  useEffect(() => {
    if (!isActive || !snapshot.usesSubscription || status !== "ready" || page !== "conversation")
      return;
    const tick = () => {
      if (document.visibilityState === "visible") agentConnection().refreshQuota();
    };
    tick();
    const handle = setInterval(tick, QUOTA_REFRESH_MILLISECONDS);
    return () => clearInterval(handle);
  }, [isActive, page, snapshot.usesSubscription, status]);

  const sessionTitle = useCallback(
    (sessionID: string): string => {
      const session = snapshot.sessions.find((entry) => entry.id === sessionID);
      const title = session === undefined ? null : historyTitle(session, history.metadata);
      return title !== null && title.trim().length > 0 ? title : t("agent.tabs.untitled");
    },
    [history.metadata, snapshot.sessions, t],
  );

  const headerTitle =
    selected === null ? t("agent.actions.newConversation") : sessionTitle(selected);

  // A tab carries its own session even while another surface shows a different
  // conversation, so it titles itself from `sessionID`, never from the global
  // selection. Hidden tabs must not rename themselves or their neighbours.
  const sessionKnown =
    sessionID === null || snapshot.sessions.some((entry) => entry.id === sessionID);
  const editorTabTitle = sessionID === null ? headerTitle : sessionTitle(sessionID);

  useEffect(() => {
    if (!isEditorPlacement || isForeignAgent || !isActive || !isConfigured || !sessionKnown) return;
    if (onTitleChange === undefined) return;
    onTitleChange(editorTabTitle);
  }, [
    editorTabTitle,
    isActive,
    isConfigured,
    isEditorPlacement,
    isForeignAgent,
    onTitleChange,
    sessionKnown,
  ]);

  const tabs = useMemo(
    () =>
      snapshot.openSessionIDs.map((id) => ({
        id,
        title: sessionTitle(id),
        isSelected: id === selected,
        isBusy: snapshot.conversations[id]?.isResponding === true,
        needsAttention:
          snapshot.conversations[id] !== undefined &&
          currentPermission(snapshot.conversations[id]) !== null,
      })),
    [selected, sessionTitle, snapshot.conversations, snapshot.openSessionIDs],
  );
  const showsTabStrip =
    showsTabs ||
    snapshot.openSessionIDs.length > 1 ||
    (selected === null && snapshot.openSessionIDs.length > 0);

  const openToolLocation = useCallback(
    (location: AgentToolLocation) => {
      const isAbsolute = location.path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(location.path);
      const absolute =
        isAbsolute || rootFolderPath === null
          ? location.path
          : joinPath(rootFolderPath, location.path);
      void handleFileSelect(absolute, false, location.line ?? undefined, undefined);
    },
    [handleFileSelect, rootFolderPath],
  );

  const [isExporting, setIsExporting] = useState(false);
  const [exportError, setExportError] = useState<string | null>(null);

  /**
   * Replay every selected transcript, then write one Markdown file. Nothing is
   * written until all transcripts are complete, so a session that cannot be
   * replayed reports an error instead of leaving a partial export.
   */
  const exportSessions = useCallback(
    async (sessionIDs: string[]) => {
      if (sessionIDs.length === 0 || isExporting) return;
      const connection = agentConnection();
      const listed = connection.getSnapshot().sessions;
      setIsExporting(true);
      setExportError(null);
      try {
        if (!sessionIDs.every((sessionID) => connection.canExportTranscript(sessionID))) {
          setExportError(t("agent.history.exportUnfinished"));
          return;
        }
        const documents: AgentHistoryDocument[] = [];
        for (const sessionID of sessionIDs) {
          const messages = await connection.historyTranscript(sessionID);
          if (messages === null) {
            setExportError(t("agent.history.exportUnfinished"));
            return;
          }
          const session = listed.find((entry) => entry.id === sessionID);
          documents.push({
            id: sessionID,
            title: session === undefined ? null : historyTitle(session, history.metadata),
            messages,
          });
        }
        await saveHistoryMarkdown(
          historyMarkdown(documents, {
            untitled: t("agent.tabs.untitled"),
            you: t("agent.history.you"),
            tool: t("agent.history.tool"),
            thinking: t("agent.history.thinking"),
          }),
          {
            title: t("agent.history.export"),
            fileType: t("agent.history.exportFileType"),
            tooLarge: t("agent.history.exportTooLarge"),
            failed: t("agent.history.exportFailed"),
          },
        );
      } catch (error) {
        setExportError(
          error instanceof AgentHistoryExportError
            ? error.message
            : t("agent.history.exportFailed"),
        );
      } finally {
        setIsExporting(false);
      }
    },
    [history.metadata, isExporting, t],
  );

  const openSettings = useCallback(() => setPage("settings"), []);

  const historyList = (onSelect: (sessionID: string) => void) => (
    <AgentHistoryList
      sessions={snapshot.sessions}
      metadata={history.metadata}
      conversations={snapshot.conversations}
      isRefreshing={snapshot.isRefreshingSessions}
      error={snapshot.historyError ?? history.error ?? exportError}
      canRefresh={snapshot.canLoadSessions && status === "ready"}
      onRefresh={() => agentConnection().refreshSessions()}
      onSelect={onSelect}
      onRename={history.rename}
      onSetFavorite={(sessionIDs, favorite) => void history.setFavorite(sessionIDs, favorite)}
      onSetHidden={(sessionIDs, hidden) => void history.setHidden(sessionIDs, hidden)}
      isExporting={isExporting}
      onExport={(sessionIDs) => void exportSessions(sessionIDs)}
      canExportSession={(sessionID) => agentConnection().canExportTranscript(sessionID)}
    />
  );

  if (isForeignAgent && boundAgentID !== null) {
    const boundAgentName = AGENT_NAMES[boundAgentID] ?? boundAgentID;
    const activeAgentName = AGENT_NAMES[settings.agentId] ?? settings.agentId;
    return (
      <PanelFrame placement={placement}>
        <AgentPanelHeader title={t("agent.editor.foreignAgentTitle")}>
          {onMoveToToolWindow === undefined ? null : (
            <AgentToolbarButton
              label={t("agent.actions.moveToToolWindow")}
              onClick={onMoveToToolWindow}
            >
              <CaretDoubleRightIcon className="size-3.5" />
            </AgentToolbarButton>
          )}
          <AgentToolbarButton label={t("agent.actions.close")} onClick={onClose}>
            <XIcon className="size-3.5" />
          </AgentToolbarButton>
        </AgentPanelHeader>
        <AgentEmptyState
          icon={<WarningIcon />}
          title={t("agent.editor.foreignAgentTitle")}
          message={t("agent.editor.foreignAgentMessage", {
            agent: boundAgentName,
            current: activeAgentName,
          })}
          action={{
            label: t("agent.editor.switchBack", { agent: boundAgentName }),
            onClick: switchToBoundAgent,
          }}
          secondaryAction={{ label: t("agent.actions.close"), onClick: onClose }}
        />
      </PanelFrame>
    );
  }

  if (page === "settings") {
    return (
      <PanelFrame placement={placement}>
        <div className="flex h-[34px] shrink-0 items-center gap-2 border-border border-b bg-surface px-2">
          <AgentToolbarButton
            label={t("agent.settings.back")}
            onClick={() => setPage("conversation")}
          >
            <CaretLeftIcon className="size-3" />
          </AgentToolbarButton>
          <span className="flex-1 font-semibold text-foreground ui-text-sm">
            {t("agent.settings.title")}
          </span>
          <AgentToolbarButton label={t("agent.actions.close")} onClick={onClose}>
            <XIcon className="size-3.5" />
          </AgentToolbarButton>
        </div>
        <div className="min-h-0 flex-1 overflow-auto">
          <AgentSettingsSection
            settings={settings}
            management={management}
            onChange={(next) => void updateSetting("agentPanel", next)}
            onReconnect={reconnect}
            canChangeAuthentication={canChangeAuthentication}
          />
        </div>
      </PanelFrame>
    );
  }

  if (page === "history") {
    return (
      <PanelFrame placement={placement}>
        <div className="flex h-[34px] shrink-0 items-center gap-2 border-border border-b bg-surface px-2">
          <AgentToolbarButton
            label={t("agent.settings.back")}
            onClick={() => setPage("conversation")}
          >
            <CaretLeftIcon className="size-3" />
          </AgentToolbarButton>
          <span className="flex-1 font-semibold text-foreground ui-text-sm">
            {t("agent.actions.history")}
          </span>
        </div>
        <div className="min-h-0 flex-1 overflow-auto">
          {historyList((sessionID) => {
            agentConnection().selectSession(sessionID);
            setPage("conversation");
          })}
        </div>
      </PanelFrame>
    );
  }

  // While an editor tab owns the conversation, the tool window becomes the
  // history manager. Selecting a row focuses that session's existing tab or
  // opens one for a session that is not placed yet.
  if (!isEditorPlacement && editorSessionIDs.length > 0) {
    const focusSessionID = editorSessionIDs[editorSessionIDs.length - 1] ?? null;
    return (
      <PanelFrame placement={placement}>
        <div className="flex h-[34px] shrink-0 items-center gap-2 border-border border-b bg-surface px-2">
          <span className="flex-1 font-semibold text-foreground ui-text-sm">
            {t("agent.actions.history")}
          </span>
          <AgentToolbarButton label={t("agent.actions.settings")} onClick={openSettings}>
            <GearIcon className="size-3.5" />
          </AgentToolbarButton>
          <AgentToolbarButton label={t("agent.actions.close")} onClick={onClose}>
            <XIcon className="size-3.5" />
          </AgentToolbarButton>
        </div>
        <AgentInlineNotice
          text={t("agent.editor.handoffNotice")}
          action={{
            label: t("agent.editor.focusTab"),
            onClick: () => {
              if (focusSessionID !== null) {
                openAgentConversationInEditor(focusSessionID, settings.agentId);
              }
            },
          }}
        />
        <div className="min-h-0 flex-1 overflow-auto">
          {historyList((sessionID) => openAgentConversationInEditor(sessionID, settings.agentId))}
        </div>
      </PanelFrame>
    );
  }

  const transcriptArea = (): ReactNode => {
    if (!isConfigured) {
      // The full layout stays visible; sending explains what is missing.
      return (
        <div className="flex h-full min-h-0 flex-col">
          <AgentHero agentName={agentName} agentVersion={null} onSwitchAgent={openSettings} />
          <AgentActivitySummaryBar messages={[]} />
          {localError === null ? null : (
            <AgentInlineNotice
              text={localError}
              action={{ label: t("agent.actions.openSettings"), onClick: openSettings }}
            />
          )}
        </div>
      );
    }
    switch (status) {
      case "idle":
      case "connecting":
        return (
          <AgentEmptyState
            icon={<SparkleIcon />}
            title={t("agent.state.starting")}
            message={t("agent.state.startingMessage")}
            isBusy
          />
        );
      case "authenticationRequired":
        return (
          <AgentEmptyState
            icon={<UserCircleIcon />}
            title={t("agent.state.signIn")}
            message={t("agent.state.signInMessage")}
            action={{
              label: t("agent.state.signInAction"),
              onClick: () => agentConnection().authenticate(),
            }}
            secondaryAction={{ label: t("agent.actions.settings"), onClick: openSettings }}
          />
        );
      case "authenticating":
        return (
          <AgentEmptyState
            icon={<UserCircleIcon />}
            title={t("agent.state.signingIn")}
            message={t("agent.state.signingInMessage")}
            isBusy
            action={{
              label: t("agent.state.cancel"),
              onClick: () => void agentConnection().cancelAuthentication(),
            }}
          />
        );
      case "failed": {
        const message =
          snapshot.connectionState.status === "failed" ? snapshot.connectionState.message : "";
        if (conversation !== null && conversation.messages.length > 0) {
          return (
            <div className="flex h-full min-h-0 flex-col">
              <div className="min-h-0 flex-1">{transcript()}</div>
              <AgentInlineNotice text={message} />
              <div className="flex justify-center pb-2">
                <button
                  type="button"
                  className="text-primary ui-text-sm hover:underline"
                  onClick={reconnect}
                >
                  {t("agent.actions.reconnect")}
                </button>
              </div>
            </div>
          );
        }
        return (
          <AgentEmptyState
            icon={<WarningIcon />}
            title={t("agent.state.failed")}
            message={message}
            action={{ label: t("agent.status.retry"), onClick: reconnect }}
            secondaryAction={{ label: t("agent.actions.settings"), onClick: openSettings }}
          />
        );
      }
      case "ready":
        return transcript();
    }
  };

  function transcript() {
    return (
      <AgentTranscript
        conversation={conversation}
        sessionID={selected}
        agentName={agentName}
        agentVersion={snapshot.agentVersion}
        pendingPrompt={selected === null ? snapshot.pendingNewConversationPrompt : null}
        pendingStartedAt={snapshot.pendingNewConversationStartedAt}
        isCreatingSession={snapshot.isCreatingSession}
        searchText={searchText}
        now={agentConnection().now}
        onSwitchAgent={openSettings}
        onOpenLocation={openToolLocation}
        onAnswerPermission={(optionID) => agentConnection().answerPermission(optionID)}
      />
    );
  }

  const inlineError =
    localError ??
    conversation?.configurationError ??
    conversation?.errorMessage ??
    snapshot.errorMessage ??
    exportError;
  // Waiting for the Agent to confirm session settings must block sending,
  // otherwise the first prompt would use a configuration nobody confirmed.
  const canSend =
    isConfigured &&
    (!isEditorPlacement || (sessionID !== null && snapshot.selectedSessionID === sessionID)) &&
    status === "ready" &&
    !snapshot.isCreatingSession &&
    conversation?.isLoading !== true &&
    conversation?.pendingConfigToken == null;

  const conversationSurface = (
    <PanelFrame placement={placement}>
      <AgentPanelHeader title={isConfigured ? headerTitle : t("agent.actions.newConversation")}>
        {isConfigured ? (
          <>
            <AgentToolbarButton
              label={t("agent.actions.search")}
              active={showsSearch}
              onClick={() => {
                setShowsSearch((value) => !value);
                setSearchText("");
              }}
            >
              <MagnifyingGlassIcon className="size-3.5" />
            </AgentToolbarButton>
            {isEditorPlacement ? null : (
              <>
                <AgentToolbarButton
                  label={t("agent.actions.newConversation")}
                  disabled={selected === null}
                  onClick={() => agentConnection().startNewConversation()}
                >
                  <PlusIcon className="size-3.5" />
                </AgentToolbarButton>
                <AgentToolbarButton
                  label={t("agent.actions.tabs")}
                  active={showsTabs}
                  onClick={() => setShowsTabs((value) => !value)}
                >
                  <SquareSplitHorizontalIcon className="size-3.5" />
                </AgentToolbarButton>
                <AgentToolbarButton
                  label={t("agent.actions.history")}
                  onClick={() => setPage("history")}
                >
                  <ClockCounterClockwiseIcon className="size-3.5" />
                </AgentToolbarButton>
              </>
            )}
          </>
        ) : null}
        {isEditorPlacement ? (
          <>
            <AgentToolbarButton
              label={
                detailsOpen ? t("agent.actions.hideDetails") : t("agent.actions.showDetails")
              }
              active={detailsOpen}
              onClick={() => surfaceActions.setDetailsOpen(!detailsOpen)}
            >
              <SidebarSimpleIcon className="size-3.5" />
            </AgentToolbarButton>
            {onMoveToToolWindow === undefined ? null : (
              <AgentToolbarButton
                label={t("agent.actions.moveToToolWindow")}
                onClick={onMoveToToolWindow}
              >
                <CaretDoubleRightIcon className="size-3.5" />
              </AgentToolbarButton>
            )}
          </>
        ) : (
          <>
            <AgentToolbarButton
              label={t("agent.actions.openInEditor")}
              disabled={!isConfigured || selected === null}
              onClick={() => {
                if (selected !== null) {
                  openAgentConversationInEditor(selected, settings.agentId);
                }
              }}
            >
              <ArrowSquareOutIcon className="size-3.5" />
            </AgentToolbarButton>
            <AgentToolbarButton label={t("agent.actions.settings")} onClick={openSettings}>
              <GearIcon className="size-3.5" />
            </AgentToolbarButton>
            <AgentToolbarButton label={t("agent.actions.close")} onClick={onClose}>
              <XIcon className="size-3.5" />
            </AgentToolbarButton>
          </>
        )}
      </AgentPanelHeader>

      {isConfigured && showsSearch ? (
        <div className="flex h-[34px] shrink-0 items-center gap-1.5 bg-muted/60 pr-1.5 pl-3">
          <MagnifyingGlassIcon className="size-3.5 text-subtle-foreground" />
          <input
            autoFocus
            value={searchText}
            placeholder={t("agent.actions.search")}
            aria-label={t("agent.actions.search")}
            className="min-w-0 flex-1 bg-transparent text-foreground outline-none ui-text-sm"
            onChange={(event) => setSearchText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                setShowsSearch(false);
                setSearchText("");
              }
            }}
          />
          <AgentToolbarButton
            label={t("agent.actions.closeSearch")}
            onClick={() => {
              setShowsSearch(false);
              setSearchText("");
            }}
          >
            <XIcon className="size-3" />
          </AgentToolbarButton>
        </div>
      ) : null}

      {isConfigured && !isEditorPlacement && showsTabStrip ? (
        <AgentConversationTabs
          tabs={tabs}
          showsNewTab={selected === null}
          isNewTabBusy={snapshot.isCreatingSession}
          newTabTitle={
            snapshot.pendingNewConversationPrompt === null
              ? null
              : provisionalTabTitle(snapshot.pendingNewConversationPrompt)
          }
          onSelect={(sessionID) => agentConnection().selectSession(sessionID)}
          onClose={(sessionID) => agentConnection().closeConversation(sessionID)}
          onNew={() => agentConnection().startNewConversation()}
        />
      ) : null}

      <AgentConversationLayout
        transcript={
          <div className="flex h-full min-h-0 flex-col">
            <div className="min-h-0 flex-1">{transcriptArea()}</div>
            {isConfigured && inlineError !== null && inlineError !== undefined ? (
              <AgentInlineNotice text={inlineError} />
            ) : null}
          </div>
        }
        composerPane={
          <div className={cn("h-full", isEditorPlacement && "mx-auto w-full max-w-[700px]")}>
            <AgentComposer
              conversation={isConfigured ? conversation : null}
              agentName={agentName}
              draft={draft}
              onDraftChange={setDraft}
              files={files}
              onFilesChange={setFiles}
              canSend={canSend}
              onOpenSettings={openSettings}
              onError={setLocalError}
              blockedReason={
                !settings.enabled
                  ? t("agent.error.disabled")
                  : rootFolderPath === null
                    ? t("agent.setup.noProject")
                    : status !== "ready"
                      ? t("agent.error.notConnected")
                      : t("agent.error.preparing")
              }
            />
          </div>
        }
      />
    </PanelFrame>
  );

  if (!isEditorPlacement) return conversationSurface;

  return (
    <div className="relative flex size-full min-h-0">
      {conversationSurface}
      {detailsOpen ? (
        <AgentSessionDetails
          title={headerTitle}
          sessionID={selected}
          agentName={agentName}
          agentVersion={snapshot.agentVersion}
          workspacePath={rootFolderPath}
          conversation={conversation}
          onClose={() => surfaceActions.setDetailsOpen(false)}
        />
      ) : null}
    </div>
  );
}

function PanelFrame({
  children,
  placement = "toolWindow",
}: {
  children: ReactNode;
  placement?: AgentPanelPlacement;
}) {
  const { t } = useTranslation();
  return (
    <section
      aria-label={t("agent.title")}
      className={cn(
        "flex h-full min-h-0 flex-col bg-background",
        placement === "editor" &&
          "mx-auto w-full max-w-[716px] border-border/60 border-x",
      )}
    >
      {children}
    </section>
  );
}

/**
 * Editor-only session details. It reports only data the Agent connection has
 * already published; MCP servers and changed files stay absent rather than
 * inventing local stand-ins.
 */
function AgentSessionDetails({
  title,
  sessionID,
  agentName,
  agentVersion,
  workspacePath,
  conversation,
  onClose,
}: {
  title: string;
  sessionID: string | null;
  agentName: string | null;
  agentVersion: string | null;
  workspacePath: string | null;
  conversation: AgentConversation | null;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  return (
    <aside
      aria-label={t("agent.details.title")}
      className="absolute inset-y-0 right-0 z-20 flex w-[280px] flex-col border-border border-l bg-surface shadow-xl xl:static xl:shadow-none"
    >
      <div className="flex h-[34px] shrink-0 items-center gap-2 border-border border-b px-2">
        <span className="flex-1 font-semibold text-foreground ui-text-sm">
          {t("agent.details.title")}
        </span>
        <AgentToolbarButton label={t("agent.actions.hideDetails")} onClick={onClose}>
          <XIcon className="size-3.5" />
        </AgentToolbarButton>
      </div>
      <div className="min-h-0 flex-1 overflow-auto p-3">
        <DetailSection title={t("agent.details.session")}>
          <DetailRow label={t("agent.details.titleLabel")} value={title} />
          <DetailRow
            label={t("agent.details.agent")}
            value={
              agentName === null
                ? "—"
                : agentVersion === null
                  ? agentName
                  : `${agentName} ${agentVersion}`
            }
          />
          <DetailRow label={t("agent.details.workspace")} value={workspacePath ?? "—"} />
          <DetailRow label={t("agent.details.sessionId")} value={sessionID ?? "—"} mono />
          <DetailRow
            label={t("agent.details.messages")}
            value={String(conversation?.messages.length ?? 0)}
          />
          <DetailRow
            label={t("agent.details.turns")}
            value={String(conversation?.completedTurns.length ?? 0)}
          />
        </DetailSection>
        <DetailSection title={t("agent.details.context")}>
          <div className="flex items-center justify-between py-0.5">
            <span className="text-subtle-foreground ui-text-caption">
              {t("agent.context.label")}
            </span>
            <AgentContextUsageView usage={conversation?.contextUsage ?? null} />
          </div>
          {conversation === null || conversation.configOptions.length === 0 ? (
            <p className="py-1 text-subtle-foreground ui-text-caption">
              {t("agent.details.noConfig")}
            </p>
          ) : (
            conversation.configOptions.map((option) => {
              const choice = option.choices.find((entry) => entry.id === option.currentValue);
              return (
                <DetailRow
                  key={option.id}
                  label={option.name}
                  value={choice?.name ?? option.currentValue}
                />
              );
            })
          )}
        </DetailSection>
        <p className="text-subtle-foreground ui-text-caption">
          {t("agent.details.unavailable")}
        </p>
      </div>
    </aside>
  );
}

function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mb-2 border-border/60 border-b pb-2 last:mb-0 last:border-b-0">
      <h3 className="mb-1 font-semibold text-subtle-foreground ui-text-caption">{title}</h3>
      {children}
    </section>
  );
}

function DetailRow({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="flex items-start justify-between gap-3 py-0.5">
      <span className="shrink-0 text-subtle-foreground ui-text-caption">{label}</span>
      <span
        className={cn(
          "min-w-0 text-right text-foreground ui-text-caption",
          mono ? "break-all font-mono" : "break-words",
        )}
      >
        {value}
      </span>
    </div>
  );
}

/**
 * Transcript above a resizable composer, as `AgentConversationLayout` on macOS:
 * the composer starts at min(210px, 30%), keeps at least min(120px, 40%) and at
 * most 60% of the height. The resize state lives in the panel group, so
 * dragging never re-renders the conversation.
 */
function AgentConversationLayout({
  transcript,
  composerPane,
}: {
  transcript: ReactNode;
  composerPane: ReactNode;
}) {
  return (
    <ResizablePanelGroup orientation="vertical" className="min-h-0 flex-1">
      <ResizablePanel id="agent-transcript" minSize="40">
        {transcript}
      </ResizablePanel>
      <ResizableHandle className="bg-transparent after:h-2" />
      <ResizablePanel id="agent-composer" defaultSize={210} minSize={120} maxSize="60">
        <div className="relative h-full pt-2.5">
          <span
            aria-hidden
            className="pointer-events-none absolute top-1 left-1/2 h-[3px] w-[54px] -translate-x-1/2 rounded-full bg-subtle-foreground/40"
          />
          {composerPane}
        </div>
      </ResizablePanel>
    </ResizablePanelGroup>
  );
}
