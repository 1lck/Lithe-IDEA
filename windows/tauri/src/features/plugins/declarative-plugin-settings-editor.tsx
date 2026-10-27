import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import Switch from "@/ui/switch";
import { Checkbox } from "@/ui/checkbox";
import NumberInput from "@/ui/number-input";
import SettingsSelect from "@/ui/settings-select";
import Input from "@/ui/input";
import { Button } from "@/ui/button";
import Section, { SettingRow } from "@/features/settings/components/settings-section";
import { pushDeclarativeWorkspaceConfiguration } from "@/platform/lsp-core-adapter";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { pluginPlanGuard, subscribePluginActivity } from "./declarative-plugin-lifecycle";
import { pluginSettingsReloads } from "./declarative-plugin-reload";
import {
  applySettingEffect,
  DeclarativeSettingsSession,
  type SettingsSessionState,
} from "./declarative-settings-session";
import {
  loadDeclarativeSettingSnapshot,
  storeDeclarativeSetting,
  declarativeWorkspaceConfiguration,
  type DeclarativePluginSetting,
  type ResolvedDeclarativeSetting,
  type DeclarativeSettingAction,
} from "./declarative-plugin-launch";

/** Explicit drafts of the host preferences actually consumed by Core. No
 * native tool file is read/copied and opening the view performs no write. */
export function DeclarativePluginSettingsEditor({
  pluginId,
  settings,
  workspacePath,
  languageId,
  actions,
}: {
  pluginId: string;
  settings: DeclarativePluginSetting[];
  workspacePath: string | null;
  languageId: string | null;
  actions?: DeclarativeSettingAction[];
}) {
  const { t } = useTranslation();
  const [state, setState] = useState<SettingsSessionState>({
    snapshot: null,
    busy: false,
    error: null,
    drafts: {},
    effect: null,
  });
  const [layer, setLayer] = useState<"global" | "project">("global");
  const [invalid, setInvalid] = useState(false);
  const [pluginRevision, setPluginRevision] = useState(0);
  useSyncExternalStore(pluginSettingsReloads.subscribe, pluginSettingsReloads.revision);
  const pendingReload = pluginSettingsReloads.state(pluginId);
  const session = useRef<DeclarativeSettingsSession | null>(null);
  useEffect(() => {
    let stale = false;
    const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
    const runtime = workspaceRuntimeRegistry.getWorkspace(workspaceId);
    const runtimePath = runtime?.descriptor.path;
    const sameWorkspace = () =>
      workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId &&
      workspaceRuntimeRegistry.getWorkspace(workspaceId) === runtime &&
      runtime?.descriptor.path === runtimePath;
    const guard = pluginPlanGuard();
    const assertCurrent = () => {
      try {
        guard(pluginId);
      } catch {
        throw new Error("plugin.settings.staleContext");
      }
      if (stale || !sameWorkspace()) throw new Error("plugin.settings.staleContext");
    };
    const invalidate = () => {
      stale = true;
      setInvalid(true);
      session.current?.dispose();
    };
    const releasePlugin = subscribePluginActivity((id) => {
      if (id === pluginId) {
        invalidate();
        setPluginRevision((revision) => revision + 1);
      }
    });
    const releaseWorkspace = workspaceRuntimeRegistry.subscribe(() => {
      if (!sameWorkspace()) invalidate();
    });
    const owned = new DeclarativeSettingsSession(
      {
        read: () => loadDeclarativeSettingSnapshot(pluginId, workspacePath ?? ""),
        write: (id, scope, value, identity) =>
          storeDeclarativeSetting(pluginId, id, scope, workspacePath ?? "", value, identity),
        assertCurrent,
        effect: (setting, snapshot, scope) =>
          applySettingEffect(
            setting,
            snapshot,
            workspacePath,
            {
              assertCurrent,
              pluginId,
              configuration: declarativeWorkspaceConfiguration,
              push: pushDeclarativeWorkspaceConfiguration,
              savedForReload: (saved, requiresReload) =>
                pluginSettingsReloads.saved(
                  {
                    pluginId,
                    workspacePath: workspacePath ?? "",
                    expectedIdentity: saved.identity,
                    expectedPackageIdentity: saved.packageIdentity,
                  },
                  requiresReload,
                ),
            },
            scope,
          ),
      },
      setState,
    );
    session.current = owned;
    setInvalid(false);
    setLayer("global");
    setState({ snapshot: null, busy: true, error: null, drafts: {}, effect: null });
    void owned.reload();
    return () => {
      owned.dispose();
      releasePlugin();
      releaseWorkspace();
      if (session.current === owned) session.current = null;
    };
  }, [pluginId, workspacePath, languageId, pluginRevision]);

  const snapshot = state.snapshot;
  const recoveryRequired = state.error?.includes("plugin.settings.recoveryRequired") ?? false;
  const visible = snapshot
    ? snapshot.settings.filter((item) => settings.some((selected) => selected.id === item.id))
    : [];
  const declaredActions = actions ?? snapshot?.settingActions ?? [];
  const sections = [
    ...new Set([...visible, ...declaredActions].map((setting) => setting.section ?? "")),
  ];
  return (
    <div className="space-y-3" data-plugin-settings={pluginId}>
      {(state.error || invalid) && (
        <p role="alert" className="text-destructive ui-text-sm">
          {recoveryRequired
            ? t("plugins.settings.recoveryRequired")
            : t("plugins.settings.failed", {
                code: invalid ? "plugin.settings.staleContext" : (state.error ?? ""),
              })}
        </p>
      )}
      {snapshot && (
        <>
          {visible.length === 0 && declaredActions.length === 0 && (
            <p role="status" className="ui-text-sm">
              {t("settings.declarativePluginDetails.empty.settings")}
            </p>
          )}
          <SettingRow
            label={t("plugins.settings.storage")}
            description={t("plugins.settings.storageInfo")}
            activateOnClick={false}
          >
            <SettingsSelect
              value={layer}
              disabled={state.busy || invalid}
              options={[
                { value: "global", label: t("settings.declarativePlugins.settingScope.global") },
                ...(workspacePath
                  ? [
                      {
                        value: "project",
                        label: t("settings.declarativePlugins.settingScope.project"),
                      },
                    ]
                  : []),
              ]}
              onChange={(value) => setLayer(value as "global" | "project")}
            />
          </SettingRow>
          <p className="break-all font-mono ui-text-sm">
            {layer === "project" ? snapshot.projectPath : snapshot.globalPath}
          </p>
          {state.effect && (
            <p role="status" className="ui-text-sm">
              {t(`plugins.settings.effect.${state.effect}`)}
            </p>
          )}
          {sections.map((section) => (
            <Section key={section} title={section || t("settings.declarativePlugins.settings")}>
              {visible
                .filter((item) => (item.section ?? "") === section)
                .map((setting) => {
                  const scope =
                    layer === "project" && setting.scope === "project" ? "project" : "global";
                  const resolved = (
                    scope === "project" ? snapshot.resolvedProject : snapshot.resolvedGlobal
                  ).find((item) => item.id === setting.id);
                  if (!resolved) return null;
                  const key = `${scope}:${setting.id}`;
                  const dirty = Object.prototype.hasOwnProperty.call(state.drafts, key);
                  const raw = scope === "project" ? snapshot.projectValues : snapshot.globalValues;
                  const disabled =
                    state.busy ||
                    !!pendingReload?.busy ||
                    invalid ||
                    recoveryRequired ||
                    (layer === "project" && setting.scope !== "project");
                  return (
                    <div key={setting.id} className="space-y-1">
                      <SettingRow
                        label={setting.title}
                        description={setting.description ?? undefined}
                        activateOnClick={false}
                        labelAccessory={
                          <span className="text-subtle-foreground ui-text-sm">
                            {t(`settings.declarativePlugins.settingSource.${resolved.source}`)} ·{" "}
                            {t(
                              `settings.declarativePlugins.settingEffect.${setting.effect ?? "restart"}`,
                            )}
                            {layer === "global" &&
                              setting.scope === "project" &&
                              snapshot.resolvedProject.some(
                                (item) => item.id === setting.id && item.source === "project",
                              ) && <> · {t("plugins.settings.projectOverride")}</>}
                          </span>
                        }
                      >
                        <SettingValueControl
                          setting={setting}
                          value={dirty ? state.drafts[key] : resolved.value}
                          disabled={disabled}
                          onChange={(value) => session.current?.edit(setting.id, scope, value)}
                        />
                      </SettingRow>
                      <div className="flex justify-end gap-2">
                        <Button
                          size="sm"
                          disabled={disabled || !dirty}
                          onClick={() => void session.current?.save(setting, scope)}
                        >
                          {t("ui.save")}
                        </Button>
                        <Button
                          size="sm"
                          disabled={disabled || !dirty}
                          onClick={() => session.current?.cancel(setting.id, scope)}
                        >
                          {t("ui.cancel")}
                        </Button>
                        <Button
                          size="sm"
                          disabled={
                            disabled || !Object.prototype.hasOwnProperty.call(raw, setting.id)
                          }
                          onClick={() => void session.current?.save(setting, scope, true)}
                        >
                          {t("plugins.settings.inherit")}
                        </Button>
                      </div>
                    </div>
                  );
                })}
              {declaredActions
                .filter((item) => (item.section ?? "") === section)
                .map((action) => (
                  <SettingRow
                    key={action.id}
                    label={action.title}
                    description={action.description}
                    activateOnClick={false}
                  >
                    <span title={t("plugins.settings.actionUnavailable")}>
                      <Button disabled>{action.title}</Button>
                    </span>
                  </SettingRow>
                ))}
            </Section>
          ))}
          {declaredActions.length > 0 && (
            <p role="status" className="ui-text-sm">
              {t("plugins.settings.actionUnavailable")}
            </p>
          )}
        </>
      )}
      <Button
        size="sm"
        disabled={state.busy || invalid}
        onClick={() => void session.current?.reload()}
      >
        {t("plugins.settings.reload")}
      </Button>
    </div>
  );
}

function SettingValueControl({
  setting,
  value,
  disabled,
  onChange,
}: {
  setting: DeclarativePluginSetting;
  value: unknown;
  disabled: boolean;
  onChange(value: unknown): void;
}) {
  if (setting.type === "boolean")
    return (
      <Switch
        checked={value === true}
        disabled={disabled}
        onChange={onChange}
        aria-label={setting.title}
      />
    );
  if (setting.type === "integer")
    return (
      <NumberInput
        value={Number(value)}
        min={setting.minimum ?? undefined}
        max={setting.maximum ?? undefined}
        disabled={disabled}
        onChange={onChange}
        aria-label={setting.title}
      />
    );
  if (setting.type === "enum")
    return (
      <SettingsSelect
        value={String(value)}
        disabled={disabled}
        options={(setting.options ?? []).map((option) => ({
          value: option.value,
          label: option.title,
        }))}
        onChange={onChange}
      />
    );
  if (setting.type === "multiSelect")
    return (
      <div className="flex flex-wrap gap-2">
        {(setting.options ?? []).map((option) => {
          const current = Array.isArray(value) ? value.map(String) : [];
          return (
            <label key={option.value} className="flex items-center gap-1 ui-text-sm">
              <Checkbox
                checked={current.includes(option.value)}
                disabled={disabled}
                aria-label={option.title}
                onCheckedChange={(checked) =>
                  onChange(
                    checked
                      ? [...new Set([...current, option.value])]
                      : current.filter((item) => item !== option.value),
                  )
                }
              />
              {option.title}
            </label>
          );
        })}
      </div>
    );
  return (
    <Input
      value={String(value ?? "")}
      disabled={disabled}
      maxLength={setting.maxLength ?? undefined}
      placeholder={setting.placeholder ?? undefined}
      aria-label={setting.title}
      onChange={(event) => onChange(event.target.value)}
    />
  );
}

export type { DeclarativePluginSetting, ResolvedDeclarativeSetting };
