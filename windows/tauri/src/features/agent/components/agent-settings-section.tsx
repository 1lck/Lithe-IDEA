import { useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import Switch from "@/ui/switch";
import Textarea from "@/ui/textarea";
import type { AgentManagement } from "../hooks/use-agent-management";
import { readAgentApiKey, storeAgentApiKey } from "../services/agent-launch";
import {
  CODEX_AGENT_ID,
  CUSTOM_AGENT_ID,
  supportsCodexSubscription,
  type AgentPanelSettings,
} from "../types/agent-settings.types";

const FALLBACK_AGENTS = [
  { id: CODEX_AGENT_ID, name: "Codex" },
  { id: "claude-acp", name: "Claude" },
];

interface AgentSettingsSectionProps {
  settings: AgentPanelSettings;
  onChange: (settings: AgentPanelSettings) => void;
  management: AgentManagement;
  /** Reconnect with what was just saved. */
  onReconnect: () => void;
}

/**
 * The Agent half of the panel's setup: which adapter runs, how it is installed,
 * and which provider or subscription it signs in with.
 */
export function AgentSettingsSection({
  settings,
  onChange,
  management,
  onReconnect,
}: AgentSettingsSectionProps) {
  const { t } = useTranslation();
  const [apiKeyDraft, setApiKeyDraft] = useState("");
  const [hasStoredKey, setHasStoredKey] = useState(false);
  const [keyError, setKeyError] = useState<string | null>(null);
  const isCustom = settings.agentId === CUSTOM_AGENT_ID;
  const isSubscription = settings.authentication === "codexSubscription";

  useEffect(() => {
    let cancelled = false;
    setApiKeyDraft("");
    if (isSubscription) {
      setHasStoredKey(false);
      return;
    }
    void readAgentApiKey(settings.agentId)
      .then((key) => {
        if (!cancelled) setHasStoredKey(key.length > 0);
      })
      .catch(() => {
        if (!cancelled) setHasStoredKey(false);
      });
    return () => {
      cancelled = true;
    };
  }, [isSubscription, settings.agentId]);

  const agentOptions = (management.status?.agents ?? FALLBACK_AGENTS).map((agent) => ({
    value: agent.id,
    label: agent.name,
  }));
  if (!agentOptions.some((option) => option.value === CUSTOM_AGENT_ID)) {
    agentOptions.push({ value: CUSTOM_AGENT_ID, label: t("agent.settings.customAgent") });
  }
  const selectedAgent = management.status?.agents.find((agent) => agent.id === settings.agentId);
  const canInstall = selectedAgent !== undefined && !isCustom;
  const isBusy = management.busyAgentId === settings.agentId;

  const saveKey = async () => {
    try {
      await storeAgentApiKey(settings.agentId, apiKeyDraft);
      setApiKeyDraft("");
      setHasStoredKey(apiKeyDraft.trim().length > 0);
      setKeyError(null);
      onReconnect();
    } catch (error) {
      setKeyError(error instanceof Error ? error.message : String(error));
    }
  };

  return (
    <div className="space-y-2 border-border/70 border-b p-2">
      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="text-foreground">{t("agent.settings.enable")}</div>
          <div className="text-subtle-foreground ui-text-caption">{t("agent.settings.enableHint")}</div>
        </div>
        <Switch
          size="sm"
          checked={settings.enabled}
          onChange={(enabled) => onChange({ ...settings, enabled })}
        />
      </div>

      <div className="flex items-center gap-2">
        <span className="w-20 shrink-0 text-subtle-foreground">{t("agent.settings.agent")}</span>
        <Select
          size="sm"
          className="min-w-0 flex-1"
          value={settings.agentId}
          options={agentOptions}
          onChange={(agentId) =>
            onChange({ ...settings, agentId, authentication: "apiKey" })
          }
        />
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          tooltip={t("agent.settings.refresh")}
          aria-label={t("agent.settings.refresh")}
          disabled={management.isRefreshing}
          onClick={() => void management.refresh()}
        >
          {management.isRefreshing ? <Spinner className="size-3.5" /> : "⟳"}
        </Button>
      </div>

      {canInstall ? (
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0 text-subtle-foreground ui-text-caption">
            {selectedAgent.installedVersion === null
              ? t("agent.settings.notInstalled", { name: selectedAgent.name })
              : t("agent.settings.installed", {
                  name: selectedAgent.name,
                  version: selectedAgent.installedVersion,
                })}
          </div>
          <Button
            type="button"
            size="xs"
            variant="accent"
            disabled={isBusy}
            onClick={() => void management.install(settings.agentId)}
          >
            {isBusy
              ? t("agent.settings.installing")
              : selectedAgent.installedVersion === null
                ? t("agent.settings.install")
                : t("agent.settings.reinstall")}
          </Button>
        </div>
      ) : null}

      {selectedAgent === undefined || selectedAgent.issues.length === 0 ? null : (
        <ul className="space-y-0.5 text-subtle-foreground ui-text-caption">
          {selectedAgent.issues.map((issue) => (
            <li key={issue}>{issue}</li>
          ))}
        </ul>
      )}
      {management.progress === null ? null : (
        <div className="text-subtle-foreground ui-text-caption">
          {t("agent.settings.progress", {
            stage: management.progress.stage,
            megabytes: (management.progress.downloadedBytes / 1_048_576).toFixed(1),
          })}
        </div>
      )}
      {management.error === null ? null : (
        <div className="text-warning ui-text-caption">{management.error}</div>
      )}

      {isCustom ? (
        <>
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 text-subtle-foreground">
              {t("agent.settings.command")}
            </span>
            <Input
              size="sm"
              className="min-w-0 flex-1"
              value={settings.command}
              placeholder="codex-acp"
              onChange={(event) => onChange({ ...settings, command: event.target.value })}
            />
          </div>
          <div className="flex flex-col gap-1">
            <span className="text-subtle-foreground">
              {t("agent.settings.arguments")}
            </span>
            <Textarea
              size="sm"
              rows={3}
              className="font-mono"
              value={settings.arguments}
              placeholder={"--flag value\n--another"}
              onChange={(event) => onChange({ ...settings, arguments: event.target.value })}
            />
          </div>
        </>
      ) : null}

      {supportsCodexSubscription(settings.agentId) ? (
        <div className="flex items-center gap-2">
          <span className="w-20 shrink-0 text-subtle-foreground">
            {t("agent.settings.authentication")}
          </span>
          <Select
            size="sm"
            className="min-w-0 flex-1"
            value={settings.authentication}
            options={[
              { value: "apiKey", label: t("agent.settings.apiKeyMode") },
              { value: "codexSubscription", label: t("agent.settings.subscriptionMode") },
            ]}
            onChange={(value) =>
              onChange({
                ...settings,
                authentication: value === "codexSubscription" ? "codexSubscription" : "apiKey",
              })
            }
          />
        </div>
      ) : null}

      {isSubscription ? (
        <div className="text-subtle-foreground ui-text-caption">
          {t("agent.settings.subscriptionHint")}
        </div>
      ) : (
        <>
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 text-subtle-foreground">
              {t("agent.settings.baseUrl")}
            </span>
            <Input
              size="sm"
              className="min-w-0 flex-1"
              value={settings.provider.baseUrl}
              placeholder="https://api.openai.com/v1"
              onChange={(event) =>
                onChange({
                  ...settings,
                  provider: { ...settings.provider, baseUrl: event.target.value },
                })
              }
            />
          </div>
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 text-subtle-foreground">
              {t("agent.settings.model")}
            </span>
            <Input
              size="sm"
              className="min-w-0 flex-1"
              value={settings.provider.model}
              placeholder={t("agent.settings.modelPlaceholder")}
              onChange={(event) =>
                onChange({
                  ...settings,
                  provider: { ...settings.provider, model: event.target.value },
                })
              }
            />
          </div>
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 text-subtle-foreground">
              {t("agent.settings.apiKey")}
            </span>
            <Input
              size="sm"
              type="password"
              className="min-w-0 flex-1"
              value={apiKeyDraft}
              placeholder={
                hasStoredKey ? t("agent.settings.apiKeyStored") : t("agent.settings.apiKeyPlaceholder")
              }
              onChange={(event) => setApiKeyDraft(event.target.value)}
            />
            <Button
              type="button"
              size="xs"
              variant="accent"
              disabled={apiKeyDraft.trim().length === 0}
              onClick={() => void saveKey()}
            >
              {t("agent.settings.saveKey")}
            </Button>
          </div>
          <div className="flex items-center justify-between gap-2">
            <div className="text-subtle-foreground ui-text-caption">
              {t("agent.settings.allowInsecureHint")}
            </div>
            <Switch
              size="sm"
              checked={settings.provider.allowInsecureHttp}
              onChange={(allowInsecureHttp) =>
                onChange({
                  ...settings,
                  provider: { ...settings.provider, allowInsecureHttp },
                })
              }
            />
          </div>
          <div className="flex items-center justify-between">
            <span className="text-subtle-foreground ui-text-caption">
              {t("agent.settings.reconnectHint")}
            </span>
            <Button type="button" size="xs" variant="ghost" onClick={onReconnect}>
              {t("agent.settings.reconnect")}
            </Button>
          </div>
        </>
      )}
      {keyError === null ? null : <div className="text-warning ui-text-caption">{keyError}</div>}
    </div>
  );
}
