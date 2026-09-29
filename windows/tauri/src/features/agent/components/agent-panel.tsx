import { useCallback, useEffect, useMemo, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { GearIcon, PlusIcon, XIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import { joinPath } from "@/utils/path-helpers";
import { useAgentManagement } from "../hooks/use-agent-management";
import { useAgentSnapshot } from "../hooks/use-agent-connection";
import {
  agentConnection,
  agentDataDirectory,
  closeAgentConnection,
  openAgentConnection,
} from "../stores/agent-connection-service";
import { currentPermission, provisionalTitle } from "../types/agent.types";
import { AgentComposer } from "./agent-composer";
import { AgentConversationTabs } from "./agent-conversation-tabs";
import { AgentHistoryList } from "./agent-history-list";
import { AgentSettingsSection } from "./agent-settings-section";
import { AgentTranscript } from "./agent-transcript";

/** How often a visible subscription panel asks the host for fresh quota. */
const QUOTA_REFRESH_MILLISECONDS = 60_000;

interface AgentPanelProps {
  onClose: () => void;
}

/**
 * The Agent sidebar, aligned with `AgentConversationView` on macOS.
 *
 * It renders its whole layout even when the feature is off: the entry stays
 * discoverable, the body explains what to turn on, and no Agent process starts
 * until the panel is enabled and the project's adapter is configured.
 */
export function AgentPanel({ onClose }: AgentPanelProps) {
  const { t } = useTranslation();
  const snapshot = useAgentSnapshot();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath ?? null);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const settings = useSettingsStore((state) => state.settings.agentPanel);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const [dataDirectory, setDataDirectory] = useState<string | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const management = useAgentManagement(dataDirectory, showSettings || !settings.enabled);

  const status = snapshot.connectionState.status;
  const selected = snapshot.selectedSessionID;
  const conversation = selected === null ? null : (snapshot.conversations[selected] ?? null);

  const reconnect = useCallback(() => {
    if (!settings.enabled) {
      // Turning the feature off stops the Agent processes; the panel stays open.
      void closeAgentConnection();
      return;
    }
    if (rootFolderPath === null) return;
    void openAgentConnection(rootFolderPath, settings).catch(() => undefined);
  }, [rootFolderPath, settings]);

  useEffect(() => {
    void agentDataDirectory()
      .then(setDataDirectory)
      .catch(() => setDataDirectory(null));
  }, []);

  // Connecting is idempotent, so settings edits simply re-ask for the project.
  useEffect(() => {
    reconnect();
  }, [reconnect]);

  useEffect(() => {
    if (!snapshot.usesSubscription || status !== "ready") return;
    const tick = () => {
      if (document.visibilityState === "visible") agentConnection().refreshQuota();
    };
    tick();
    const handle = setInterval(tick, QUOTA_REFRESH_MILLISECONDS);
    return () => clearInterval(handle);
  }, [snapshot.usesSubscription, status]);

  const titles = useMemo(() => {
    const map: Record<string, string | null> = {};
    for (const [sessionID, entry] of Object.entries(snapshot.conversations)) {
      const firstUserMessage = entry.messages.find((message) => message.role === "user");
      map[sessionID] = firstUserMessage === undefined ? null : provisionalTitle(firstUserMessage.text);
    }
    return map;
  }, [snapshot.conversations]);

  const openToolLocation = useCallback(
    (path: string, line: number | null) => {
      const isAbsolute = path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path);
      const absolute =
        isAbsolute || rootFolderPath === null ? path : joinPath(rootFolderPath, path);
      void handleFileSelect(absolute, false, line ?? undefined, undefined);
    },
    [handleFileSelect, rootFolderPath],
  );

  const answerPermission = useCallback((optionID: string | null) => {
    agentConnection().answerPermission(optionID);
  }, []);

  const canSend =
    status === "ready" &&
    (conversation === null ||
      (!conversation.isResponding &&
        !conversation.isLoading &&
        conversation.pendingConfigToken === null &&
        currentPermission(conversation) === null));

  return (
    <section aria-label={t("agent.title")} className="flex h-full min-h-0 flex-col bg-background">
      <header className="flex items-center gap-1.5 border-border/70 border-b px-2 py-1.5">
        <span className="min-w-0 flex-1 truncate text-foreground ui-text-sm">
          {snapshot.agentName ?? t("agent.title")}
          {snapshot.agentVersion === null ? "" : ` ${snapshot.agentVersion}`}
        </span>
        {snapshot.usesSubscription ? (
          <span className="max-w-32 truncate text-subtle-foreground ui-text-caption">
            {snapshot.subscriptionEmail ?? snapshot.subscriptionPlan ?? t("agent.subscription.signedIn")}
          </span>
        ) : null}
        <Button
          type="button"
          size="icon-xs"
          variant="ghost"
          tooltip={t("agent.actions.newConversation")}
          aria-label={t("agent.actions.newConversation")}
          disabled={status !== "ready"}
          onClick={() => agentConnection().startNewConversation()}
        >
          <PlusIcon className="size-3.5" />
        </Button>
        <Button
          type="button"
          size="icon-xs"
          variant="ghost"
          active={showSettings}
          tooltip={t("agent.actions.settings")}
          aria-label={t("agent.actions.settings")}
          onClick={() => setShowSettings((value) => !value)}
        >
          <GearIcon className="size-3.5" />
        </Button>
        <Button
          type="button"
          size="icon-xs"
          variant="ghost"
          tooltip={t("agent.actions.close")}
          aria-label={t("agent.actions.close")}
          onClick={onClose}
        >
          <XIcon className="size-3.5" />
        </Button>
      </header>

      {showSettings ? (
        <AgentSettingsSection
          settings={settings}
          management={management}
          onChange={(next) => void updateSetting("agentPanel", next)}
          onReconnect={reconnect}
        />
      ) : null}

      {snapshot.errorMessage === null ? null : (
        <div className="border-border/70 border-b px-2 py-1 text-warning ui-text-caption">
          {snapshot.errorMessage}
        </div>
      )}

      <AgentConnectionStatus
        status={status}
        message={status === "failed" ? snapshot.connectionState.message : null}
        usesSubscription={snapshot.usesSubscription}
        enabled={settings.enabled}
        canStart={rootFolderPath !== null}
        onRetry={() => {
          void agentConnection()
            .stop()
            .then(reconnect)
            .catch(() => undefined);
        }}
        onEnable={() => void updateSetting("agentPanel", { ...settings, enabled: true })}
        onOpenSettings={() => setShowSettings(true)}
      />

      <AgentHistoryList
        sessions={snapshot.sessions}
        isRefreshing={snapshot.isRefreshingSessions}
        error={snapshot.historyError}
        canRefresh={snapshot.canLoadSessions && status === "ready"}
        onRefresh={() => agentConnection().refreshSessions()}
        onSelect={(sessionID) => agentConnection().selectSession(sessionID)}
      />

      <AgentConversationTabs
        openSessionIDs={snapshot.openSessionIDs}
        sessions={snapshot.sessions}
        selectedSessionID={selected}
        titles={titles}
        onSelect={(sessionID) => agentConnection().selectSession(sessionID)}
        onClose={(sessionID) => agentConnection().closeConversation(sessionID)}
      />

      <div className="min-h-0 flex-1 overflow-auto">
        {conversation === null ? (
          <div className="p-3 text-subtle-foreground ui-text-sm">
            {status === "ready" ? t("agent.transcript.pickSession") : null}
          </div>
        ) : (
          <AgentTranscript
            conversation={conversation}
            onOpenToolLocation={openToolLocation}
            onAnswerPermission={answerPermission}
          />
        )}
      </div>

      {status === "ready" ? (
        <AgentComposer conversation={conversation} canSend={canSend} />
      ) : null}
    </section>
  );
}

interface AgentConnectionStatusProps {
  status: string;
  message: string | null;
  usesSubscription: boolean;
  enabled: boolean;
  canStart: boolean;
  onRetry: () => void;
  onEnable: () => void;
  onOpenSettings: () => void;
}

/** One line that explains the current state and offers the next action. */
function AgentConnectionStatus({
  status,
  message,
  usesSubscription,
  enabled,
  canStart,
  onRetry,
  onEnable,
  onOpenSettings,
}: AgentConnectionStatusProps) {
  const { t } = useTranslation();

  if (!enabled) {
    return (
      <div className="space-y-1.5 border-border/70 border-b p-2">
        <div className="text-foreground ui-text-sm">{t("agent.setup.disabled")}</div>
        <div className="flex gap-1.5">
          <Button type="button" size="xs" variant="accent" onClick={onEnable}>
            {t("agent.setup.enable")}
          </Button>
          <Button type="button" size="xs" variant="ghost" onClick={onOpenSettings}>
            {t("agent.setup.openSettings")}
          </Button>
        </div>
      </div>
    );
  }
  if (!canStart) {
    return (
      <div className="border-border/70 border-b p-2 text-subtle-foreground ui-text-sm">
        {t("agent.setup.noProject")}
      </div>
    );
  }
  if (status === "connecting") {
    return (
      <div className="flex items-center gap-1.5 border-border/70 border-b p-2 text-subtle-foreground ui-text-sm">
        <Spinner className="size-3.5" />
        {t("agent.status.connecting")}
      </div>
    );
  }
  if (status === "authenticationRequired" && usesSubscription) {
    return (
      <div className="space-y-1.5 border-border/70 border-b p-2">
        <div className="text-foreground ui-text-sm">{t("agent.subscription.required")}</div>
        <Button
          type="button"
          size="xs"
          variant="accent"
          onClick={() => agentConnection().authenticate()}
        >
          {t("agent.subscription.signIn")}
        </Button>
      </div>
    );
  }
  if (status === "authenticating") {
    return (
      <div className="flex items-center gap-1.5 border-border/70 border-b p-2">
        <Spinner className="size-3.5" />
        <span className="flex-1 text-subtle-foreground ui-text-sm">
          {t("agent.subscription.authenticating")}
        </span>
        <Button
          type="button"
          size="xs"
          variant="ghost"
          onClick={() => void agentConnection().cancelAuthentication()}
        >
          {t("agent.subscription.cancelSignIn")}
        </Button>
      </div>
    );
  }
  if (status === "failed") {
    return (
      <div className="space-y-1.5 border-border/70 border-b p-2">
        <div className="text-warning ui-text-sm">{message ?? t("agent.status.failed")}</div>
        <div className="flex gap-1.5">
          <Button type="button" size="xs" variant="ghost" onClick={onRetry}>
            {t("agent.status.retry")}
          </Button>
          <Button type="button" size="xs" variant="ghost" onClick={onOpenSettings}>
            {t("agent.setup.openSettings")}
          </Button>
        </div>
      </div>
    );
  }
  return null;
}
