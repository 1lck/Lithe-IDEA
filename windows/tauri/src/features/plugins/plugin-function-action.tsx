import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { SettingRow } from "@/features/settings/components/settings-section";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { pluginPlanGuard, subscribePluginActivity } from "./declarative-plugin-lifecycle";
import type { DeclarativeSettingAction } from "./declarative-plugin-launch";
import { createPluginFunctionSession, pluginFunctionCleanup } from "./plugin-functions";
import type { FunctionState, PluginFunctionSession } from "./plugin-function-session";

const initial: FunctionState = { phase: "idle", review: null, progress: null, error: null };
export function PluginFunctionAction({
  pluginId,
  action,
  workspacePath,
  identity,
  disabled = false,
  createSession = createPluginFunctionSession,
}: {
  pluginId: string;
  action: DeclarativeSettingAction;
  workspacePath: string | null;
  identity: string;
  disabled?: boolean;
  createSession?: typeof createPluginFunctionSession;
}) {
  const { t } = useTranslation();
  const [state, setState] = useState(initial);
  const session = useRef<PluginFunctionSession | null>(null);
  const [attempt, setAttempt] = useState(0);
  const prepareAgain = useRef(false);
  useEffect(() => {
    const workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
    const runtime = workspaceRuntimeRegistry.getWorkspace(workspaceId);
    const path = runtime?.descriptor.path;
    const guard = pluginPlanGuard();
    const assertCurrent = () => {
      guard(pluginId);
      if (
        !workspacePath ||
        workspaceRuntimeRegistry.getActiveWorkspaceId() !== workspaceId ||
        workspaceRuntimeRegistry.getWorkspace(workspaceId) !== runtime ||
        runtime?.descriptor.path !== path
      )
        throw new Error("plugin.function.staleContext");
    };
    const owned = createSession(
      {
        pluginId,
        actionId: action.id,
        workspacePath: workspacePath ?? "",
        expectedIdentity: identity,
        operationId: crypto.randomUUID(),
      },
      assertCurrent,
      setState,
    );
    session.current = owned;
    setState(initial);
    if (prepareAgain.current) {
      prepareAgain.current = false;
      void owned.prepare();
    }
    const releasePlugin = subscribePluginActivity((id) => {
      if (id === pluginId) owned.dispose();
    });
    const releaseWorkspace = workspaceRuntimeRegistry.subscribe(() => {
      try {
        assertCurrent();
      } catch {
        owned.dispose();
      }
    });
    return () => {
      owned.dispose();
      releasePlugin();
      releaseWorkspace();
      if (session.current === owned) session.current = null;
    };
  }, [pluginId, action.id, workspacePath, identity, attempt, createSession]);
  const active = [
    "preparing",
    "review",
    "starting",
    "running",
    "stopping",
    "cleanupFailed",
  ].includes(state.phase);
  return (
    <div data-plugin-function-action={action.id} className="space-y-2">
      <SettingRow label={action.title} description={action.description} activateOnClick={false}>
        <Button
          size="sm"
          disabled={disabled || !workspacePath || active}
          onClick={() => {
            if (state.phase !== "idle") {
              prepareAgain.current = true;
              setAttempt((value) => value + 1);
              return;
            }
            void session.current?.prepare();
          }}
        >
          {state.phase === "idle" ? action.title : t("plugins.functions.newAttempt")}
        </Button>
        {active && (
          <Button
            size="sm"
            disabled={state.phase === "stopping"}
            onClick={() => void session.current?.cancel()}
          >
            {t(state.phase === "cleanupFailed" ? "plugins.functions.retryCleanup" : "ui.cancel")}
          </Button>
        )}
      </SettingRow>
      {state.phase !== "idle" && (
        <p role="status" className="ui-text-sm">
          {t(`plugins.functions.phase.${state.phase}`)}
        </p>
      )}
      {state.phase === "review" && state.review && (
        <section
          className="space-y-2 rounded border border-border p-2"
          aria-label={t("plugins.functions.review")}
        >
          <p className="ui-text-sm">
            {t(
              state.review.confirm ? "plugins.functions.confirmAction" : "plugins.functions.review",
            )}
          </p>
          <dl className="ui-text-sm">
            <dt>{t("plugins.functions.workspace")}</dt>
            <dd className="break-all">{state.review.context.workspacePath}</dd>
            <dt>{t("plugins.functions.function")}</dt>
            <dd>{state.review.context.functionId}</dd>
            <dt>{t("plugins.functions.projectCode")}</dt>
            <dd>
              {t(
                state.review.executesProjectCode ? "plugins.functions.yes" : "plugins.functions.no",
              )}
            </dd>
            <dt>{t("plugins.functions.network")}</dt>
            <dd>
              {t(state.review.mayUseNetwork ? "plugins.functions.yes" : "plugins.functions.no")}
            </dd>
          </dl>
          <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all ui-text-sm">
            {JSON.stringify(
              { program: state.review.program, launchPlan: state.review.launchPlan },
              null,
              2,
            )}
          </pre>
          <Button size="sm" disabled={disabled} onClick={() => void session.current?.confirm()}>
            {t("plugins.functions.confirm")}
          </Button>
        </section>
      )}
      {state.progress && (
        <p role="status" className="ui-text-sm">
          {state.progress.message}
          {typeof state.progress.percentage === "number" && ` ${state.progress.percentage}%`}
        </p>
      )}
      {state.phase === "succeeded" && (
        <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all ui-text-sm">
          {JSON.stringify(state.result, null, 2)}
        </pre>
      )}
      {state.error && (
        <p role="alert" className="text-destructive ui-text-sm">
          {t("plugins.functions.failed", { code: state.error.code })}{" "}
          {state.error.message !== state.error.code && state.error.message}{" "}
          {state.error.pluginErrorCode}
        </p>
      )}
    </div>
  );
}

/** Cleanup failures stay reachable after a settings page is removed. */
export function PluginFunctionCleanupNotices() {
  const { t } = useTranslation();
  useSyncExternalStore(pluginFunctionCleanup.subscribe, pluginFunctionCleanup.revision);
  return (
    <>
      {pluginFunctionCleanup.pending().map((owner) => (
        <div
          key={owner.input.operationId}
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
    </>
  );
}
