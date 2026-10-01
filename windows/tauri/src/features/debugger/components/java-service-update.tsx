import { useState } from "react";
import { restartJavaServiceDebug } from "@/features/maven/services/maven-module-debug";
import { useTranslation } from "@/i18n/locale-provider";
import { useStore } from "zustand";
import { useRunStore } from "@/features/run/stores/run.store";
import { Button } from "@/ui/button";
import type { DebugSession } from "../types/debugger.types";

export function JavaServiceUpdate({ session }: { session: DebugSession }) {
  const { t } = useTranslation();
  const [restarting, setRestarting] = useState(false);
  const [restartError, setRestartError] = useState<string | null>(null);
  const reference = session.javaRun!;
  const store = useRunStore.getStore(reference.workspaceId);
  const update = useStore(store, (state) => state.serviceUpdates[reference.sessionId]);
  if (
    !update || update.executionId !== reference.executionId ||
    (session.status === "idle" && !restartError && !restarting)
  ) return null;
  return (
    <div className="flex items-center gap-2">
      <Button
        size="xs"
        variant="ghost"
        disabled={update.pending || restarting || session.status === "idle"}
        tooltip={t("debugger.applyCodeChangesHelp")}
        onClick={() => void store.getState().actions.updateService(reference.sessionId, session.id)}
      >
        {update.pending ? t("debugger.applyingCodeChanges") : t("debugger.applyCodeChanges")}
      </Button>
      {update.failed ? (
        <Button size="xs" disabled={update.pending || restarting} onClick={() => {
          setRestarting(true);
          setRestartError(null);
          void restartJavaServiceDebug(session).catch((error) => {
            setRestartError(error instanceof Error ? error.message : String(error));
          }).finally(() => setRestarting(false));
        }}>
          {t("debugger.restartService")}
        </Button>
      ) : null}
      {restartError ? <span role="alert">{restartError}</span> : null}
      {update.message ? (
        <span role="status" className="max-w-80 truncate ui-text-sm" title={update.message}>
          {update.message}
        </span>
      ) : null}
    </div>
  );
}
