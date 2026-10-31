import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { SettingRow } from "@/features/settings/components/settings-section";
import AppDialog from "@/ui/dialog";
import BuildProviderReviewDetails from "@/features/build-systems/components/build-provider-review";
import type { ApproveBuildModel } from "@/features/build-systems/build-systems-service";
import type { BuildModelReview } from "@/features/build-systems/build-systems-types";
import {
  pluginSettingsReloads,
  type PluginSettingsReloads,
  type PluginReloadState,
} from "./declarative-plugin-reload";

/** The mutation may remove the originating settings page. Its retry action
 * belongs to the dialog, so stop failures survive page/workspace changes. */
export function DeclarativePluginReloadNotices({
  reloads = pluginSettingsReloads,
}: { reloads?: PluginSettingsReloads } = {}) {
  useSyncExternalStore(reloads.subscribe, reloads.revision);
  const pending = reloads.states();
  if (!pending.length) return null;
  return (
    <div className="max-h-40 shrink-0 overflow-y-auto px-4" data-plugin-reload-notices="">
      {pending.map((state) => (
        <ReloadNotice key={reloads.key(state.receipt)} reloads={reloads} state={state} />
      ))}
    </div>
  );
}

function ReloadNotice({
  reloads,
  state: { receipt, busy, error, cancellable },
}: {
  reloads: PluginSettingsReloads;
  state: PluginReloadState;
}) {
  const { t } = useTranslation();
  const key = reloads.key(receipt);
  const [review, setReview] = useState<BuildModelReview | null>(null);
  const decision = useRef<((value: boolean) => void) | null>(null);
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      decision.current?.(false);
    };
  }, []);
  const approve: ApproveBuildModel = (next, signal) =>
    new Promise((resolve) => {
      if (signal.aborted || !mounted.current) {
        resolve(false);
        return;
      }
      decision.current?.(false);
      let settled = false;
      const decide = (accepted: boolean) => {
        if (settled) return;
        settled = true;
        signal.removeEventListener("abort", abort);
        decision.current = null;
        if (mounted.current) setReview(null);
        resolve(accepted);
      };
      const abort = () => decide(false);
      decision.current = decide;
      signal.addEventListener("abort", abort, { once: true });
      setReview(next);
    });
  return (
    <div data-plugin-reload={receipt.pluginId} data-plugin-reload-scope={receipt.scope ?? "global"}>
      <SettingRow
        label={receipt.pluginId}
        description={t(
          receipt.scope === "project"
            ? "plugins.settings.reloadProjectInfo"
            : "plugins.settings.reloadPluginInfo",
        )}
        activateOnClick={false}
      >
        <span className="ui-text-sm" title={receipt.workspacePath}>
          {t(`settings.declarativePlugins.settingScope.${receipt.scope ?? "global"}`)}
        </span>
        {(!error || reloads.canPostpone(key)) && (
          <Button
            size="sm"
            disabled={busy}
            data-plugin-reload-postpone=""
            onClick={() => reloads.postpone(key)}
          >
            {t("plugins.settings.reloadLater")}
          </Button>
        )}
        <Button
          size="sm"
          disabled={busy}
          data-plugin-reload-confirm=""
          onClick={() => void reloads.confirm(key, approve)}
        >
          {t(busy ? "plugins.settings.reloadingPlugin" : "plugins.settings.reloadPlugin")}
        </Button>
        {busy && cancellable && receipt.scope === "project" && (
          <Button size="sm" data-plugin-reload-cancel="" onClick={() => reloads.cancel(key)}>
            {t("ui.cancel")}
          </Button>
        )}
      </SettingRow>
      {error && (
        <p role="alert" className="text-destructive ui-text-sm">
          {t("plugins.settings.failed", { code: error })}
        </p>
      )}
      {review && (
        <AppDialog
          title={t("buildSystems.model.reviewTitle")}
          size="sm"
          onClose={() => decision.current?.(false)}
          footer={
            <>
              <Button onClick={() => decision.current?.(false)}>
                {t("buildSystems.model.decline")}
              </Button>
              <Button variant="accent" onClick={() => decision.current?.(true)}>
                {t("buildSystems.model.approve")}
              </Button>
            </>
          }
        >
          <p className="break-all ui-text-sm">
            {review.pluginId} · {review.buildSystemId} · {review.workspaceRoot} · {review.root}
          </p>
          <p className="ui-text-sm">
            {t(
              review.executesProjectCode
                ? "buildSystems.model.projectCode"
                : "buildSystems.model.noProjectCode",
            )}
          </p>
          <p className="ui-text-sm">
            {t(
              review.mayUseNetwork ? "buildSystems.model.network" : "buildSystems.model.noNetwork",
            )}
          </p>
          {review.provider && <BuildProviderReviewDetails review={review.provider} />}
        </AppDialog>
      )}
    </div>
  );
}
