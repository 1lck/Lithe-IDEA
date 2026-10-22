import { useEffect, useRef, useState, type CSSProperties } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { showConfirmDialog } from "@/ui/dialog";
import { CheckIcon, EyeIcon, EyeSlashIcon } from "@/ui/icons";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import Switch from "@/ui/switch";
import Textarea from "@/ui/textarea";
import { cn } from "@/utils/cn";
import { readAgentCliConfiguration } from "@/platform/agent-cli-configuration";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { AgentManagement } from "../hooks/use-agent-management";
import { readAgentApiKey } from "../services/agent-launch";
import { agentProviderCredential } from "../services/agent-provider-credentials";
import {
  agentProviderConfigSource,
  importAgentProviderConfiguration,
  importedProviderMatchesAgent,
  agentProviderConfigurationText,
} from "../services/agent-provider-import";
import {
  CLAUDE_AGENT_ID,
  CODEX_AGENT_ID,
  CUSTOM_AGENT_ID,
  defaultAgentModel,
  agentProviders,
  addAgentProvider,
  removeAgentProvider,
  updateAgentProvider,
  selectAgentConfiguration,
  supportsCodexSubscription,
  type AgentPanelSettings,
} from "../types/agent-settings.types";

const FALLBACK_AGENTS = [
  { id: CODEX_AGENT_ID, name: "Codex" },
  { id: CLAUDE_AGENT_ID, name: "Claude" },
];

interface AgentSettingsSectionProps {
  settings: AgentPanelSettings;
  onChange: (settings: AgentPanelSettings) => void;
  management: AgentManagement;
  /** Reconnect with what was just saved. */
  onReconnect: () => void;
  /** A running turn or pending confirmation must not lose its provider. */
  canChangeAuthentication: boolean;
}

/**
 * The Agent half of the panel's setup: which adapter runs, how it is installed,
 * and which provider or subscription it signs in with.
 */
export function AgentSettingsSection({
  settings: savedSettings,
  onChange: commitSettings,
  management,
  onReconnect,
  canChangeAuthentication,
}: AgentSettingsSectionProps) {
  const { t } = useTranslation();
  const commitAgentProvider = useSettingsStore.use.actions().commitAgentProvider;
  const settingsError = useSettingsStore.use.agentSettingsError();
  const [editor, setEditor] = useState<{ original: AgentPanelSettings; draft: AgentPanelSettings; isNew: boolean } | null>(null);
  const settings = editor?.draft ?? savedSettings;
  const [apiKeyDraft, setApiKeyDraft] = useState("");
  const [revealsKey, setRevealsKey] = useState(false);
  const [hasStoredKey, setHasStoredKey] = useState(false);
  const [keyError, setKeyError] = useState<string | null>(null);
  const [importText, setImportText] = useState("");
  const [textMode, setTextMode] = useState(false);
  const [authenticationText, setAuthenticationText] = useState("");
  const [importError, setImportError] = useState<string | null>(null);
  const [isImporting, setIsImporting] = useState(false);
  const [isSavingKey, setIsSavingKey] = useState(false);
  const [isReadingKey, setIsReadingKey] = useState(false);
  const latest = useRef({ settings: savedSettings, canChangeAuthentication });
  latest.current = { settings: savedSettings, canChangeAuthentication };
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const currentOperation = () => mounted.current && latest.current.settings === savedSettings && latest.current.canChangeAuthentication;
  const disabled = !canChangeAuthentication || isSavingKey || isImporting || management.busyAgentId !== null;
  const isCustom = settings.agentId === CUSTOM_AGENT_ID;
  const isSubscription = settings.authentication === "codexSubscription";
  const configSource = agentProviderConfigSource(settings.agentId);
  const providers = agentProviders(settings);
  const onChange = (next: AgentPanelSettings) => {
    if (editor !== null) {
      setEditor({ ...editor, draft: next });
      return;
    }
    if (next.provider !== settings.provider && next.provider.id === settings.provider.id) {
      const updated = updateAgentProvider(settings, next.provider);
      commitSettings({ ...next, provider: updated.provider, providers: updated.providers });
    } else commitSettings(next);
  };

  useEffect(() => {
    setImportText(configSource === null ? "" : agentProviderConfigurationText(configSource, settings.provider));
    setImportError(null);
    setAuthenticationText("");
  }, [configSource, settings.provider]);

  useEffect(() => {
    let cancelled = false;
    setApiKeyDraft("");
    setRevealsKey(false);
    setKeyError(null);
    setHasStoredKey(false);
    setIsReadingKey(!isSubscription);
    if (isSubscription) {
      setHasStoredKey(false);
      return;
    }
    void readAgentApiKey(settings.agentId, settings.provider.id)
      .then((key) => {
        if (!cancelled) {
          setHasStoredKey(key.length > 0);
          if (editor !== null && !editor.isNew) setApiKeyDraft(key);
        }
      })
      .catch((error) => {
        if (!cancelled) setKeyError(t("agent.settings.keyFailed"));
      })
      .finally(() => { if (!cancelled) setIsReadingKey(false); });
    return () => {
      cancelled = true;
    };
  }, [isSubscription, settings.agentId, settings.provider.id, editor?.original, editor?.isNew]);

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
  const cli = selectedAgent?.cli ?? null;
  const cliUpdate = management.cliUpdates[settings.agentId] ?? null;
  // A missing CLI is installed through its own vendor, and the host only offers
  // an automatic update when it verified the installation owner.
  const canInstallCli = canInstall && cli !== null && (cli.detected === null || cli.installation.canUpdate);

  const saveKey = async (value = apiKeyDraft) => {
    if (disabled) return;
    setIsSavingKey(true);
    try {
      await commitAgentProvider(settings, settings, { agentId: settings.agentId, providerId: settings.provider.id, value });
      if (!mounted.current) return;
      setApiKeyDraft("");
      setHasStoredKey(value.trim().length > 0);
      setKeyError(null);
      onReconnect();
    } catch (error) {
      if (currentOperation()) setKeyError(t("agent.settings.keyFailed"));
    } finally {
      if (mounted.current) setIsSavingKey(false);
    }
  };

  const saveProvider = async () => {
    if (editor === null || disabled) return;
    setIsSavingKey(true);
    try {
      let provider = settings.provider;
      let key = apiKeyDraft;
      if (textMode && configSource !== null) {
        const parsed = await importAgentProviderConfiguration(configSource, importText);
        if (!importedProviderMatchesAgent(settings.agentId, parsed)) throw new Error("agent.settings.importProtocolMismatch");
        provider = { ...provider, ...parsed, source: undefined };
        key = agentProviderCredential(configSource, importText, authenticationText);
      }
      if (!provider.name.trim() || !provider.baseUrl.trim() || !provider.model.trim() || !key.trim()) throw new Error("agent.settings.requiredProviderFields");
      let endpoint: URL;
      try { endpoint = new URL(provider.baseUrl); }
      catch { throw new Error("agent.settings.invalidProviderUrl"); }
      if (endpoint.username || endpoint.password || !["https:", "http:"].includes(endpoint.protocol) ||
          (endpoint.protocol === "http:" && !provider.allowInsecureHttp)) throw new Error("agent.settings.invalidProviderUrl");
      const next = editor.isNew
        ? { ...settings, provider, providers: agentProviders({ ...settings, provider }) }
        : updateAgentProvider(editor.original, provider);
      await commitAgentProvider(editor.original, next, { agentId: settings.agentId, providerId: next.provider.id, value: key });
      if (!mounted.current) return;
      setEditor(null);
      setApiKeyDraft("");
      setAuthenticationText("");
      setImportError(null);
      onReconnect();
    } catch (error) {
      if (mounted.current) {
        const code = error instanceof Error ? error.message : "";
        setImportError(t(code.startsWith("agent.settings.") ? code : "agent.settings.importFailed"));
      }
    } finally {
      if (mounted.current) setIsSavingKey(false);
    }
  };

  const importConfiguration = async (local = false) => {
    if (configSource === null || disabled) return false;
    setIsImporting(true);
    try {
      const configuration = local ? await readAgentCliConfiguration(configSource) : importText;
      const provider = await importAgentProviderConfiguration(configSource, configuration, true);
      if (!currentOperation()) return false;
      if (!importedProviderMatchesAgent(settings.agentId, provider)) {
        setImportError(t("agent.settings.importProtocolMismatch"));
        return false;
      }
      const providerSettings = {
          ...settings.provider,
          source: local ? settings.provider.source : undefined,
          protocol: provider.protocol,
          baseUrl: provider.baseUrl,
          model: provider.model,
      };
      const key = local ? "" : agentProviderCredential(configSource, configuration, authenticationText);
      if (editor !== null) {
        onChange({ ...settings, provider: providerSettings });
        if (key) setApiKeyDraft(key);
        // Import consumes the text into the form draft, including its secret.
        setTextMode(false);
      } else {
        await commitAgentProvider(savedSettings, updateAgentProvider(savedSettings, providerSettings));
      }
      if (!mounted.current) return false;
      setAuthenticationText("");
      setImportError(null);
      return true;
    } catch (error) {
      if (currentOperation()) setImportError(error instanceof Error && error.message === "agent.settings.configurationTooLarge"
        ? t(error.message) : t("agent.settings.importFailed"));
      return false;
    } finally {
      if (mounted.current) setIsImporting(false);
    }
  };

  return (
    <fieldset disabled={disabled} className="min-w-0 space-y-2 border-border/70 border-b p-2">
      <fieldset disabled={editor !== null} className="min-w-0 space-y-2">
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

      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0"><div>{t("agent.stats.observe")}</div><div className="text-subtle-foreground ui-text-caption">{t("agent.stats.observeHint")}</div></div>
        <Switch size="sm" checked={settings.observeModelCalls ?? true} disabled={!canChangeAuthentication} onChange={(observeModelCalls) => onChange({ ...settings, observeModelCalls })} />
      </div>
      <div className="flex items-center gap-2">
        <span className="w-20 shrink-0 text-subtle-foreground">{t("agent.settings.agent")}</span>
        <Select
          size="sm"
          className="min-w-0 flex-1"
          value={settings.agentId}
          options={agentOptions}
          disabled={disabled}
          onChange={(agentId) => onChange(selectAgentConfiguration(settings, agentId))}
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
          {selectedAgent.installedVersion === null ? null : (
            <Button type="button" size="xs" variant="ghost" disabled={isBusy} onClick={() => void management.uninstall(settings.agentId)}>
              {t("agent.settings.uninstall")}
            </Button>
          )}
        </div>
      ) : null}

      {canInstall && cli !== null ? (
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0 text-subtle-foreground ui-text-caption">
            {cli.detected === null
              ? t("agent.settings.cliMissing", {
                  name: cli.name,
                  version: cli.minimumVersion,
                })
              : t("agent.settings.cliDetected", {
                  name: cli.name,
                  version: cli.detected.version,
                })}
          </div>
          {canInstallCli ? (
            <Button
              type="button"
              size="xs"
              variant="ghost"
              disabled={isBusy}
              title={cli.installation.updateHint}
              onClick={() => void management.installCli(settings.agentId)}
            >
              {isBusy
                ? t("agent.settings.updatingCli")
                : cli.detected === null
                  ? t("agent.settings.installCli")
                  : t("agent.settings.updateCli")}
            </Button>
          ) : null}
        </div>
      ) : null}

      {canInstallCli || cli === null ? null : (
        <div className="text-subtle-foreground ui-text-caption">{cli.installation.updateHint}</div>
      )}

      {cliUpdate === null ? null : (
        <>
          <div className="text-subtle-foreground ui-text-caption">
            {t("agent.settings.cliUpdated", { version: cliUpdate.cliVersion })}
          </div>
          {cliUpdate.updaterWarning === null ? null : (
            <div className="text-warning ui-text-caption">
              {t("agent.settings.cliUpdateWarning", { warning: cliUpdate.updaterWarning })}
            </div>
          )}
        </>
      )}

      {selectedAgent === undefined || selectedAgent.issues.length === 0 ? null : (
        <ul className="space-y-0.5 text-subtle-foreground ui-text-caption">
          {selectedAgent.issues.map((issue) => (
            <li key={issue}>{issue}</li>
          ))}
        </ul>
      )}
      {management.status === null ? null : (
        <details className="break-all text-subtle-foreground ui-text-caption">
          <summary>{t("agent.settings.preflight")}</summary>
          <div>Node.js: {management.status.environment.node?.version ?? "—"} {management.status.environment.node?.path}</div>
          <div>npm: {management.status.environment.npm?.version ?? "—"} {management.status.environment.npm?.path}</div>
          <div>{selectedAgent?.package} {selectedAgent?.version} · {selectedAgent?.protocol}</div>
          <div>{cli?.detected?.path} · {cli?.installation.source}</div>
        </details>
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
        <div className="flex items-center gap-2 py-1.5">
          <span
            aria-hidden
            className={cn(
              "flex size-4 shrink-0 items-center justify-center rounded-full border",
              isSubscription
                ? "border-primary bg-primary text-primary-foreground"
                : "border-subtle-foreground/60 text-subtle-foreground",
            )}
          >
            {isSubscription ? <CheckIcon className="size-2.5" /> : null}
          </span>
          <div className="min-w-0 flex-1">
            <div className="text-foreground">{t("agent.settings.subscriptionMode")}</div>
            <div className="text-subtle-foreground ui-text-caption">
              {t("agent.settings.subscriptionRowHint")}
            </div>
          </div>
          <Button
            type="button"
            size="xs"
            variant={isSubscription ? "ghost" : "accent"}
            disabled={!canChangeAuthentication}
            title={
              canChangeAuthentication ? undefined : t("agent.settings.busyAuthentication")
            }
            onClick={() => {
              onChange({
                ...settings,
                authentication: isSubscription ? "apiKey" : "codexSubscription",
              });
              onReconnect();
            }}
          >
            {isSubscription
              ? t("agent.settings.useApiKey")
              : t("agent.settings.enableSubscription")}
          </Button>
        </div>
      ) : null}

      {isSubscription ? (
        <div className="text-subtle-foreground ui-text-caption">
          {t("agent.settings.subscriptionHint")}
        </div>
      ) : null}
      </fieldset>
      {isSubscription ? null : (
        <>
          <div className="flex items-center gap-2">
            <Select size="sm" className="min-w-0 flex-1" value={settings.provider.id ?? "legacy"}
              disabled={disabled || editor !== null}
              options={providers.map((provider, index) => ({ value: provider.id ?? "legacy", label: provider.name || provider.baseUrl || `${t("agent.settings.provider")} ${index + 1}` }))}
              onChange={(id) => {
                const provider = providers.find((entry) => (entry.id ?? "legacy") === id);
                if (provider) commitSettings({ ...settings, providers, provider });
              }} />
            <Button type="button" size="xs" variant="ghost" disabled={editor !== null || providers.length >= 32} onClick={() => {
              setEditor({ original: savedSettings, draft: addAgentProvider(savedSettings), isNew: true });
              setTextMode(false);
            }}>{t("agent.settings.addProvider")}</Button>
            <Button type="button" size="xs" variant="ghost" disabled={editor !== null || Boolean(settings.provider.source)} onClick={() => {
              setEditor({ original: savedSettings, draft: savedSettings, isNew: false });
              setTextMode(false);
            }}>{t("agent.settings.editProvider")}</Button>
            <Button type="button" size="xs" variant="ghost" disabled={editor !== null} onClick={async () => {
              const confirmed = await showConfirmDialog(t("agent.settings.removeProviderConfirm"), {
                title: t("agent.settings.removeProvider"), confirmLabel: t("agent.settings.removeProvider"), cancelLabel: t("ui.cancel"),
              });
              if (!confirmed || !currentOperation()) return;
              setIsSavingKey(true);
              void commitAgentProvider(settings, removeAgentProvider(settings), { agentId: settings.agentId, providerId: settings.provider.id, value: "" })
                .catch(() => { if (currentOperation()) setKeyError(t("agent.settings.keyFailed")); })
                .finally(() => { if (mounted.current) setIsSavingKey(false); });
            }}>{t("agent.settings.removeProvider")}</Button>
          </div>
          {configSource === null ? null : <div className="flex items-center justify-between gap-2">
            <span className="text-subtle-foreground ui-text-caption">{t("agent.settings.linkLocal")}</span>
            <Switch size="sm" disabled={editor !== null} checked={settings.provider.source === configSource} onChange={(linked) =>
              onChange({ ...settings, provider: { ...settings.provider, source: linked ? configSource : undefined } })} />
          </div>}
          {configSource === null || editor !== null ? null : <Button type="button" size="xs" variant="ghost" onClick={() => void importConfiguration(true)}>{t("agent.settings.readLocalConfiguration")}</Button>}
          <fieldset disabled={editor === null || isReadingKey || Boolean(settings.provider.source)} className="min-w-0 space-y-2">
          {configSource === null ? null : <Button type="button" size="xs" variant="ghost" onClick={async () => {
            if (!textMode) {
              setImportText(agentProviderConfigurationText(configSource, settings.provider, apiKeyDraft));
              setAuthenticationText(configSource === "codex" ? JSON.stringify({ OPENAI_API_KEY: apiKeyDraft }, null, 2) : "");
              setTextMode(true);
            }
            else if (importText.trim().length === 0 || await importConfiguration()) setTextMode(false);
          }}>
            {t(textMode ? "agent.settings.formMode" : "agent.settings.textMode")}
          </Button>}
          {textMode && configSource !== null ? null : <>
          <Input size="sm" aria-label={t("agent.settings.providerName")} placeholder={t("agent.settings.providerName")} value={settings.provider.name}
            onChange={(event) => onChange({ ...settings, provider: { ...settings.provider, name: event.target.value } })} />
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 text-subtle-foreground">
              {t("agent.settings.baseUrl")}
            </span>
            <Input
              size="sm"
              aria-label={t("agent.settings.baseUrl")}
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
              aria-label={t("agent.settings.model")}
              className="min-w-0 flex-1"
              value={settings.provider.model}
              placeholder={
                defaultAgentModel(settings.agentId) || t("agent.settings.modelPlaceholder")
              }
              onChange={(event) =>
                onChange({
                  ...settings,
                  provider: { ...settings.provider, model: event.target.value },
                })
              }
            />
          </div>
          </>}
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 text-subtle-foreground">
              {t("agent.settings.apiKey")}
            </span>
            <Input
              size="sm"
              aria-label={t("agent.settings.apiKey")}
              type={revealsKey ? "text" : "password"}
              className="min-w-0 flex-1"
              value={apiKeyDraft}
              placeholder={
                hasStoredKey ? t("agent.settings.apiKeyStored") : t("agent.settings.apiKeyPlaceholder")
              }
              onChange={(event) => setApiKeyDraft(event.target.value)}
            />
            <Button type="button" size="icon-sm" variant="ghost"
              aria-label={t(revealsKey ? "agent.settings.hideKey" : "agent.settings.showKey")}
              onClick={() => setRevealsKey(!revealsKey)}>
              {revealsKey ? <EyeSlashIcon className="size-3.5" /> : <EyeIcon className="size-3.5" />}
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
          {configSource === null || !textMode ? null : (
            <div className="flex flex-col gap-1 border-border/70 border-t pt-2">
              <span className="text-subtle-foreground">
                {t("agent.settings.importConfiguration")}
              </span>
              <Textarea
                size="sm"
                rows={4}
                className="font-mono"
                style={revealsKey ? undefined : { WebkitTextSecurity: "disc" } as CSSProperties}
                aria-label={t("agent.settings.importConfiguration")}
                value={importText}
                onChange={(event) => setImportText(event.target.value)}
              />
              {configSource === "codex" ? <>
                <div className="flex items-center justify-between gap-2">
                  <span>{t("agent.settings.authJson")}</span>
                  <Button type="button" size="icon-sm" variant="ghost" aria-label={t(revealsKey ? "agent.settings.hideKey" : "agent.settings.showKey")} onClick={() => setRevealsKey(!revealsKey)}>
                    {revealsKey ? <EyeSlashIcon className="size-3.5" /> : <EyeIcon className="size-3.5" />}
                  </Button>
                </div>
                <Textarea size="sm" rows={3} className="font-mono" style={revealsKey ? undefined : { WebkitTextSecurity: "disc" } as CSSProperties} aria-label={t("agent.settings.authJson")}
                  placeholder={t("agent.settings.authJson")} value={authenticationText} onChange={(event) => setAuthenticationText(event.target.value)} />
              </> : null}
              <div className="flex items-center justify-between gap-2">
                <span className="min-w-0 text-subtle-foreground ui-text-caption">
                  {t("agent.settings.importConfigurationHint")}
                </span>
                <Button
                  type="button"
                  size="xs"
                  variant="ghost"
                  disabled={isImporting || importText.trim().length === 0}
                  onClick={() => void importConfiguration()}
                >
                  {isImporting
                    ? t("agent.settings.importingConfiguration")
                    : t("agent.settings.importConfigurationAction")}
                </Button>
                <Button type="button" size="xs" variant="ghost" onClick={() => void importConfiguration(true)}>{t("agent.settings.readLocalConfiguration")}</Button>
              </div>
              {importError === null ? null : (
                <div className="text-warning ui-text-caption">{importError}</div>
              )}
            </div>
          )}
          </fieldset>
          {editor === null ? (hasStoredKey && !settings.provider.source ? <Button type="button" size="xs" variant="ghost" onClick={() => void saveKey("")}>{t("agent.settings.unlinkKey")}</Button> : null) : <div className="flex justify-end gap-2">
            <Button type="button" size="xs" variant="ghost" onClick={() => { setEditor(null); setApiKeyDraft(""); setAuthenticationText(""); setImportError(null); setTextMode(false); }}>{t("ui.cancel")}</Button>
            <Button type="button" size="xs" variant="accent" disabled={isReadingKey || !settings.provider.name.trim() || (!textMode && (!settings.provider.baseUrl.trim() || !settings.provider.model.trim() || !apiKeyDraft.trim()))} onClick={() => void saveProvider()}>{t("ui.save")}</Button>
          </div>}
          {importError === null ? null : <div role="alert" className="text-warning ui-text-caption">{importError}</div>}
          <div className="flex items-center justify-between">
            <span className="text-subtle-foreground ui-text-caption">{t("agent.settings.reconnectHint")}</span>
            <Button type="button" size="xs" variant="ghost" onClick={onReconnect}>{t("agent.settings.reconnect")}</Button>
          </div>
        </>
      )}
      {keyError === null ? null : <div className="text-warning ui-text-caption">{keyError}</div>}
      {settingsError === null ? null : <div role="alert" className="text-warning ui-text-caption">{t(settingsError)}</div>}
    </fieldset>
  );
}
