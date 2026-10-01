import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import {
  CaretLeftIcon,
  ClockCounterClockwiseIcon,
  GearIcon,
  MagnifyingGlassIcon,
  PlusIcon,
  SparkleIcon,
  SquareSplitHorizontalIcon,
  UserCircleIcon,
  WarningIcon,
  XIcon,
} from "@/ui/icons";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { joinPath } from "@/utils/path-helpers";
import { useAgentManagement } from "../hooks/use-agent-management";
import { useAgentSnapshot } from "../hooks/use-agent-connection";
import { useAgentHistory } from "../hooks/use-agent-history";
import { AgentHistoryExportError, saveHistoryMarkdown } from "../services/agent-history-save";
import { historyMarkdown, type AgentHistoryDocument } from "../services/agent-history-export";
import { historyTitle } from "../services/agent-history-view";
import { provisionalTabTitle } from "../services/agent-transcript-items";
import {
  agentConnection,
  agentDataDirectory,
  closeAgentConnection,
  openAgentConnection,
} from "../stores/agent-connection-service";
import { CODEX_AGENT_ID, CLAUDE_AGENT_ID } from "../types/agent-settings.types";
import { currentPermission, type AgentToolLocation } from "../types/agent.types";
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

/** How often a visible subscription panel asks the host for fresh quota. */
const QUOTA_REFRESH_MILLISECONDS = 60_000;

/** Display names of the built-in agents, as the macOS agent options show them. */
const AGENT_NAMES: Record<string, string> = {
  [CODEX_AGENT_ID]: "Codex",
  [CLAUDE_AGENT_ID]: "Claude",
};

type AgentPanelPage = "conversation" | "settings" | "history";

interface AgentPanelProps {
  onClose: () => void;
}

/**
 * The Agent sidebar, matching `AgentConversationView` on macOS.
 *
 * Settings and history replace the conversation as whole pages, the
 * conversation always shows its full layout, and sending validates the setup
 * instead of hiding the composer. No Agent process starts until the panel is
 * enabled and the project's adapter is configured.
 */
export function AgentPanel({ onClose }: AgentPanelProps) {
  const { t } = useTranslation();
  const snapshot = useAgentSnapshot();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath ?? null);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const settings = useSettingsStore((state) => state.settings.agentPanel);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const history = useAgentHistory(rootFolderPath, settings.agentId);
  const [dataDirectory, setDataDirectory] = useState<string | null>(null);
  const [page, setPage] = useState<AgentPanelPage>("conversation");
  const management = useAgentManagement(dataDirectory, page === "settings" || !settings.enabled);
  const [showsSearch, setShowsSearch] = useState(false);
  const [searchText, setSearchText] = useState("");
  const [showsTabs, setShowsTabs] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);

  const status = snapshot.connectionState.status;
  const selected = snapshot.selectedSessionID;
  const conversation = selected === null ? null : (snapshot.conversations[selected] ?? null);
  const agentName = AGENT_NAMES[settings.agentId] ?? snapshot.agentName;
  const isConfigured = settings.enabled && rootFolderPath !== null;

  const connect = useCallback(() => {
    if (!settings.enabled) {
      // Turning the feature off stops the Agent processes; the panel stays open.
      void closeAgentConnection();
      return;
    }
    if (rootFolderPath === null) return;
    void openAgentConnection(rootFolderPath, settings).catch(() => undefined);
  }, [rootFolderPath, settings]);

  const reconnect = useCallback(() => {
    void agentConnection()
      .stop()
      .then(connect)
      .catch(() => undefined);
  }, [connect]);

  useEffect(() => {
    void agentDataDirectory()
      .then(setDataDirectory)
      .catch(() => setDataDirectory(null));
  }, []);

  // Connecting is idempotent, so settings edits simply re-ask for the project.
  useEffect(() => {
    connect();
  }, [connect]);

  useEffect(() => {
    if (status === "ready") agentConnection().prepareConversation();
  }, [status]);

  // Quota polls only while the conversation itself is visible, as on macOS.
  useEffect(() => {
    if (!snapshot.usesSubscription || status !== "ready" || page !== "conversation") return;
    const tick = () => {
      if (document.visibilityState === "visible") agentConnection().refreshQuota();
    };
    tick();
    const handle = setInterval(tick, QUOTA_REFRESH_MILLISECONDS);
    return () => clearInterval(handle);
  }, [page, snapshot.usesSubscription, status]);

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

  if (page === "settings") {
    return (
      <PanelFrame>
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
          />
        </div>
      </PanelFrame>
    );
  }

  if (page === "history") {
    return (
      <PanelFrame>
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
          <AgentHistoryList
            sessions={snapshot.sessions}
            metadata={history.metadata}
            conversations={snapshot.conversations}
            isRefreshing={snapshot.isRefreshingSessions}
            error={snapshot.historyError ?? history.error ?? exportError}
            canRefresh={snapshot.canLoadSessions && status === "ready"}
            onRefresh={() => agentConnection().refreshSessions()}
            onSelect={(sessionID) => {
              agentConnection().selectSession(sessionID);
              setPage("conversation");
            }}
            onRename={history.rename}
            onSetFavorite={(sessionIDs, favorite) => void history.setFavorite(sessionIDs, favorite)}
            onSetHidden={(sessionIDs, hidden) => void history.setHidden(sessionIDs, hidden)}
            isExporting={isExporting}
            onExport={(sessionIDs) => void exportSessions(sessionIDs)}
            canExportSession={(sessionID) => agentConnection().canExportTranscript(sessionID)}
          />
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
  const canSend =
    isConfigured &&
    status === "ready" &&
    !snapshot.isCreatingSession &&
    conversation?.isLoading !== true;

  return (
    <PanelFrame>
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
        ) : null}
        <AgentToolbarButton label={t("agent.actions.settings")} onClick={openSettings}>
          <GearIcon className="size-3.5" />
        </AgentToolbarButton>
        <AgentToolbarButton label={t("agent.actions.close")} onClick={onClose}>
          <XIcon className="size-3.5" />
        </AgentToolbarButton>
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

      {isConfigured && showsTabStrip ? (
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
        composer={
          <AgentComposer
            conversation={isConfigured ? conversation : null}
            agentName={agentName}
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
        }
      />
    </PanelFrame>
  );
}

function PanelFrame({ children }: { children: ReactNode }) {
  const { t } = useTranslation();
  return (
    <section aria-label={t("agent.title")} className="flex h-full min-h-0 flex-col bg-background">
      {children}
    </section>
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
  composer,
}: {
  transcript: ReactNode;
  composer: ReactNode;
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
          {composer}
        </div>
      </ResizablePanel>
    </ResizablePanelGroup>
  );
}
