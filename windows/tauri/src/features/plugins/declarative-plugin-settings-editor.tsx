import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import Switch from "@/ui/switch";
import NumberInput from "@/ui/number-input";
import SettingsSelect from "@/ui/settings-select";
import {
  resolveDeclarativeSettings,
  storeDeclarativeSetting,
  declarativeWorkspaceConfiguration,
  type DeclarativePluginSetting,
  type ResolvedDeclarativeSetting,
} from "./declarative-plugin-launch";

/**
 * Editor for one accepted plugin's declared settings. Value semantics live in
 * Core (`plugins.declarative.resolveSettings`); this view only renders
 * controls, applies the declared scope/effect, and reports "immediate"
 * changes to a running server through `workspaceConfiguration`.
 *
 * The workspace path arrives when a workspace feature mounts the editor;
 * without one, project-scoped settings fall back to the global layer and the
 * scope badge says so.
 */
export function DeclarativePluginSettingsEditor({
  pluginId,
  settings,
  workspacePath,
  languageId,
}: {
  pluginId: string;
  settings: DeclarativePluginSetting[];
  workspacePath: string | null;
  languageId: string | null;
}) {
  const { t } = useTranslation();
  const [values, setValues] = useState<ResolvedDeclarativeSetting[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const outcome = await resolveDeclarativeSettings({ id: pluginId }, workspacePath ?? "");
      if (outcome.status !== "ok") {
        setError(t("settings.declarativePlugins.settingsUnavailable"));
        return;
      }
      setValues(outcome.settings ?? []);
    } catch (reason) {
      setError(String(reason));
    }
  }, [pluginId, workspacePath, t]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const apply = async (setting: DeclarativePluginSetting, value: unknown) => {
    setBusy(true);
    setError(null);
    try {
      const scope = setting.scope === "project" && workspacePath ? "project" : "global";
      // The default is forgotten so later default changes flow through.
      const stored = value === setting.default ? null : value;
      await storeDeclarativeSetting(pluginId, setting.id, scope, workspacePath ?? "", stored);
      await refresh();
      if (setting.effect === "immediate" && languageId) {
        await declarativeWorkspaceConfiguration(
          { id: pluginId },
          languageId,
          workspacePath ?? "",
        );
      }
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  if (!values.length) return null;
  return (
    <div className="mt-2 flex flex-col gap-2 border-t border-border pt-2">
      <h4 className="ui-text-sm font-semibold">{t("settings.declarativePlugins.settings")}</h4>
      {error && (
        <p role="alert" className="text-destructive ui-text-sm">
          {error}
        </p>
      )}
      {settings.map((setting) => {
        const resolved = values.find((value) => value.id === setting.id);
        if (!resolved) return null;
        return (
          <SettingControl
            key={setting.id}
            setting={setting}
            resolved={resolved}
            disabled={busy}
            projectAvailable={setting.scope === "project" && Boolean(workspacePath)}
            onApply={(value) => void apply(setting, value)}
          />
        );
      })}
    </div>
  );
}

function SettingControl({
  setting,
  resolved,
  disabled,
  projectAvailable,
  onApply,
}: {
  setting: DeclarativePluginSetting;
  resolved: ResolvedDeclarativeSetting;
  disabled: boolean;
  projectAvailable: boolean;
  onApply: (value: unknown) => void;
}) {
  const { t } = useTranslation();
  const sourceLabel = t(`settings.declarativePlugins.settingSource.${resolved.source}`);
  const effectLabel = setting.effect
    ? t(`settings.declarativePlugins.settingEffect.${setting.effect}`)
    : t("settings.declarativePlugins.settingEffect.restart");
  const scopeLabel = projectAvailable
    ? t("settings.declarativePlugins.settingScope.project")
    : t("settings.declarativePlugins.settingScope.global");

  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0">
        <p className="truncate ui-text-sm">
          {setting.title}
          <span className="text-subtle-foreground">
            {" "}
            · {sourceLabel} · {scopeLabel} · {effectLabel}
          </span>
        </p>
        {setting.description && (
          <p className="text-subtle-foreground ui-text-sm">{setting.description}</p>
        )}
      </div>
      {setting.type === "boolean" ? (
        <Switch
          checked={resolved.value === true}
          disabled={disabled}
          onChange={onApply}
          aria-label={setting.title}
        />
      ) : setting.type === "integer" ? (
        <NumberInput
          value={Number(resolved.value ?? 0)}
          min={setting.minimum ?? undefined}
          max={setting.maximum ?? undefined}
          disabled={disabled}
          onChange={(value: number) => onApply(value)}
          aria-label={setting.title}
        />
      ) : setting.type === "enum" ? (
        <SettingsSelect
          value={String(resolved.value ?? "")}
          disabled={disabled}
          options={(setting.options ?? []).map((option) => ({
            value: option.value,
            label: option.label,
          }))}
          onChange={onApply}
        />
      ) : (
        <input
          type="text"
          className="w-40 rounded border border-border bg-background px-2 py-1 ui-text-sm"
          value={String(resolved.value ?? "")}
          disabled={disabled}
          onChange={(event) => onApply(event.target.value)}
          aria-label={setting.title}
        />
      )}
    </div>
  );
}

export type { DeclarativePluginSetting, ResolvedDeclarativeSetting };
