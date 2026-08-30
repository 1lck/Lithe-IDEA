import { invoke } from "@/platform/tauri-core";
import { useCallback, useEffect, useState } from "react";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import Section, {
  SETTINGS_CONTROL_WIDTHS,
  SettingRow,
} from "@/features/settings/components/settings-section";
import { useTranslation } from "@/i18n/locale-provider";
import {
  CodexIntegrationService,
  getCodexSettings,
  saveCodexSettings,
} from "./codex-integration-service";
import type { CodexIntegrationStatus, CodexThreadSettings } from "./codex-types";
import { useProjectStore } from "@/features/window/stores/project.store";

export function CodexSettings() {
  const cwd = useProjectStore((state) => state.rootFolderPath || ".");
  const [status, setStatus] = useState<CodexIntegrationStatus | null>(null);
  const [settings, setSettings] = useState<CodexThreadSettings>(getCodexSettings);
  const [models, setModels] = useState<any[]>([]);
  const [details, setDetails] = useState({ skills: 0, mcp: 0, threads: 0 });
  const [busy, setBusy] = useState(false);
  const { t } = useTranslation();
  const effortOptions = [
    { value: "low", label: t("codexSettings.effortLow") },
    { value: "medium", label: t("codexSettings.effortMedium") },
    { value: "high", label: t("codexSettings.effortHigh") },
    { value: "xhigh", label: t("codexSettings.effortExtraHigh") },
  ];
  const sandboxOptions = [
    { value: "read-only", label: t("codexSettings.sandboxReadOnly") },
    { value: "workspace-write", label: t("codexSettings.sandboxWorkspaceWrite") },
    { value: "danger-full-access", label: t("codexSettings.sandboxFullAccess") },
  ];
  const approvalOptions = [
    { value: "on-request", label: t("codexSettings.approvalAskWhenNeeded") },
    { value: "untrusted", label: t("codexSettings.approvalUntrustedCommands") },
    { value: "never", label: t("codexSettings.approvalNeverAsk") },
  ];

  const connect = useCallback(async () => {
    setBusy(true);
    try {
      setStatus(await invoke<CodexIntegrationStatus>("start_codex_integration", { args: { cwd } }));
      const [modelResult, skillsResult, mcpResult, threadResult] = await Promise.all([
        invoke<any>("list_codex_models"),
        invoke<any>("list_codex_skills", { cwd }),
        invoke<any>("list_codex_mcp_servers"),
        invoke<any>("list_codex_threads", { cwd, cursor: null }),
      ]);
      setModels(modelResult.data ?? modelResult.models ?? []);
      setDetails({
        skills: (skillsResult.data ?? skillsResult.skills ?? []).length,
        mcp: (mcpResult.data ?? mcpResult.servers ?? []).length,
        threads: (threadResult.data ?? threadResult.threads ?? []).length,
      });
    } finally {
      setBusy(false);
      setStatus(await CodexIntegrationService.status().catch(() => null));
    }
  }, [cwd]);

  useEffect(() => {
    void CodexIntegrationService.status()
      .then(setStatus)
      .catch(() => {});
  }, []);

  const update = (patch: Partial<CodexThreadSettings>) => {
    const next = { ...settings, ...patch };
    setSettings(next);
    saveCodexSettings(next);
  };

  return (
    <Section
      title={t("codexSettings.title")}
      description={t("codexSettings.description")}
    >
      <SettingRow
        label={t("codexSettings.cli")}
        description={
          status?.version ?? status?.error ?? t("codexSettings.installCliDescription")
        }
      >
        <div className="flex items-center gap-2">
          <Badge variant="default">
            {status?.initialized
              ? t("projectPicker.connected")
              : status?.installed
                ? t("codexSettings.installed")
                : t("codexSettings.unavailable")}
          </Badge>
          <Button
            size="sm"
            variant="default"
            onClick={() => void connect()}
            disabled={!status?.installed || busy}
          >
            {busy ? (
              <Spinner compact label={t("projectPicker.connecting")} />
            ) : status?.initialized ? (
              t("database.refresh")
            ) : (
              t("database.connect")
            )}
          </Button>
        </div>
      </SettingRow>
      <SettingRow label={t("aiSettings.model")} description={t("codexSettings.modelDescription")}>
        <Select
          value={settings.model ?? ""}
          options={models.map((model) => ({
            value: model.id ?? model.model,
            label: model.displayName ?? model.name ?? model.id,
          }))}
          placeholder={t("codexSettings.defaultModel")}
          onChange={(model) => update({ model })}
          className={SETTINGS_CONTROL_WIDTHS.xwide}
          searchable
        />
      </SettingRow>
      <SettingRow label={t("codexSettings.reasoning")} description={t("codexSettings.reasoningDescription")}>
        <Select
          value={settings.effort ?? "medium"}
          options={effortOptions}
          onChange={(effort) => update({ effort })}
          className={SETTINGS_CONTROL_WIDTHS.wide}
        />
      </SettingRow>
      <SettingRow label={t("codexSettings.workspaceAccess")} description={t("codexSettings.workspaceAccessDescription")}>
        <Select
          value={settings.sandbox ?? "workspace-write"}
          options={sandboxOptions}
          onChange={(sandbox) => update({ sandbox })}
          className={SETTINGS_CONTROL_WIDTHS.wide}
        />
      </SettingRow>
      <SettingRow label={t("codexSettings.approvals")} description={t("codexSettings.approvalsDescription")}>
        <Select
          value={settings.approvalPolicy ?? "on-request"}
          options={approvalOptions}
          onChange={(approvalPolicy) => update({ approvalPolicy })}
          className={SETTINGS_CONTROL_WIDTHS.wide}
        />
      </SettingRow>
      <SettingRow
        label={t("codexSettings.capabilities")}
        description={t("codexSettings.capabilitiesDescription")}
      >
        <div className="flex items-center gap-1.5">
          <Badge variant="default">{t("codexSettings.threadsCount", { count: details.threads })}</Badge>
          <Badge variant="default">{t("codexSettings.skillsCount", { count: details.skills })}</Badge>
          <Badge variant="default">{details.mcp} MCP</Badge>
        </div>
      </SettingRow>
      <SettingRow label={t("codexSettings.account")} description={t("codexSettings.accountDescription")}>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="default"
            onClick={() => void invoke("start_codex_login", { loginType: "chatgpt" })}
          >
            {t("codexSettings.signIn")}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => void invoke("logout_codex_account")}>
            {t("codexSettings.signOut")}
          </Button>
        </div>
      </SettingRow>
    </Section>
  );
}
