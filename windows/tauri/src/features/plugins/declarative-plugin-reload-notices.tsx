import { useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { SettingRow } from "@/features/settings/components/settings-section";
import { pluginSettingsReloads, type PluginSettingsReloads } from "./declarative-plugin-reload";

/** The mutation may remove the originating settings page. Its retry action
 * belongs to the dialog, so stop failures survive page/workspace changes. */
export function DeclarativePluginReloadNotices({
  reloads = pluginSettingsReloads,
}: { reloads?: PluginSettingsReloads } = {}) {
  const { t } = useTranslation();
  useSyncExternalStore(reloads.subscribe, reloads.revision);
  const pending = reloads.states();
  if (!pending.length) return null;
  return (
    <div className="max-h-40 shrink-0 overflow-y-auto px-4" data-plugin-reload-notices="">
      {pending.map(({ receipt, busy, error }) => (
        <div key={receipt.pluginId} data-plugin-reload={receipt.pluginId}>
          <SettingRow
            label={receipt.pluginId}
            description={t("plugins.settings.reloadPluginInfo")}
            activateOnClick={false}
          >
            {(!error || reloads.canPostpone(receipt.pluginId)) && (
              <Button
                size="sm"
                disabled={busy}
                data-plugin-reload-postpone=""
                onClick={() => reloads.postpone(receipt.pluginId)}
              >
                {t("plugins.settings.reloadLater")}
              </Button>
            )}
            <Button
              size="sm"
              disabled={busy}
              data-plugin-reload-confirm=""
              onClick={() => void reloads.confirm(receipt.pluginId)}
            >
              {t(busy ? "plugins.settings.reloadingPlugin" : "plugins.settings.reloadPlugin")}
            </Button>
          </SettingRow>
          {error && (
            <p role="alert" className="text-destructive ui-text-sm">
              {t("plugins.settings.failed", { code: error })}
            </p>
          )}
        </div>
      ))}
    </div>
  );
}
