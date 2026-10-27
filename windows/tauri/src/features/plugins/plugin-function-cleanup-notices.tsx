import { useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { pluginFunctionCleanup } from "./plugin-functions";

/** Cleanup failures stay reachable after their originating page is removed. */
export function PluginFunctionCleanupNotices() {
  const { t } = useTranslation();
  useSyncExternalStore(pluginFunctionCleanup.subscribe, pluginFunctionCleanup.revision);
  const pending = pluginFunctionCleanup.pending();
  if (pending.length === 0) return null;
  return (
    <div className="max-h-48 shrink-0 overflow-y-auto">
      {pending.map((owner) => (
        <div
          key={owner.key ?? owner.input.operationId}
          className="flex items-center justify-between px-4 ui-text-sm"
          data-plugin-function-cleanup=""
        >
          <span>
            {owner.input.pluginId} · {owner.input.actionId} ·{" "}
            {t(`plugins.functions.phase.${owner.state.phase}`)}
          </span>
          <Button
            size="sm"
            disabled={owner.state.phase === "stopping"}
            onClick={() => void owner.cancel()}
          >
            {t("plugins.functions.retryCleanup")}
          </Button>
        </div>
      ))}
    </div>
  );
}
