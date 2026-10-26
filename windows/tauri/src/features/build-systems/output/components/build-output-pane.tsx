import { useCallback, useEffect, useMemo, useRef, useSyncExternalStore } from "react";
import { useStore, type StoreApi } from "zustand";
import { useTranslation } from "@/i18n/locale-provider";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import {
  paneHeaderClassName,
  paneTitleClassName,
  PaneIconButton,
} from "@/features/panes/components/pane-chrome";
import {
  useActiveWorkspaceId,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { CheckCircleIcon, StopIcon, TrashIcon, XCircleIcon, XIcon } from "@/ui/icons";
import { EmptyState } from "@/ui/empty";
import { Spinner } from "@/ui/spinner";
import { cn } from "@/utils/cn";
import {
  BUILD_OUTPUT_STORE_KEY,
  useBuildOutputStore,
  type BuildOutputState,
  type BuildOutputSessionState,
} from "../build-output-store";
import type { BuildOutputPort } from "../build-output-types";
import BuildOutputLog from "./build-output-log";
import BuildOutputProblems from "./build-output-problems";
import BuildOutputTestsSummary from "./build-output-tests";

/**
 * Generic, mountable output panel of one build-system instance: the bounded
 * run log, Core-decoded diagnostics and test results, and the run state.
 * Everything live — chunks, terminals, decoded results, cancellation — flows
 * through the injected `port` owned by the build run coordinator, and all
 * display state is bound to the one operation identity captured when the run
 * began, so late events of an older operation or another workspace are
 * dropped by the store. Closing or switching the panel only clears this
 * subscription; whether the run itself is cancelled follows the coordinator's
 * ownership rules and happens solely through the stop control.
 */

function failureMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export interface BuildOutputPaneProps {
  sessionId: string;
  port: BuildOutputPort;
  onReveal?: (path: string, line: number, column?: number) => void;
  onClose?: () => void;
  /** Production coordinator subscribed before execute and owns ingestion. */
  managedEvents?: boolean;
}

export default function BuildOutputPane(props: BuildOutputPaneProps) {
  const { t } = useTranslation();
  const activeWorkspaceId = useActiveWorkspaceId();
  const scopedWorkspaceId = useWorkspaceStoreScopeId();
  const workspaceId = scopedWorkspaceId ?? activeWorkspaceId;
  const getSnapshot = useCallback(
    () =>
      (workspaceRuntimeRegistry.getWorkspace(workspaceId)?.stores.get(BUILD_OUTPUT_STORE_KEY) as
        | StoreApi<BuildOutputState>
        | undefined) ?? null,
    [workspaceId],
  );
  const store = useSyncExternalStore(workspaceRuntimeRegistry.subscribe, getSnapshot, getSnapshot);
  // getStore emits a registry change on first acquisition. Acquire in an
  // effect so switching workspaces never updates another pane during render.
  useEffect(() => {
    if (!store && workspaceRuntimeRegistry.hasWorkspace(workspaceId))
      useBuildOutputStore.getStore(workspaceId);
  }, [store, workspaceId]);
  return store ? (
    <BuildOutputPaneContent
      key={workspaceId}
      {...props}
      store={store}
      workspaceId={workspaceId}
      scoped={scopedWorkspaceId !== null}
    />
  ) : (
    <EmptyState message={t("buildOutput.emptyState")} />
  );
}

function BuildOutputPaneContent({
  sessionId,
  port,
  onReveal,
  onClose,
  store,
  workspaceId,
  scoped,
  managedEvents = false,
}: BuildOutputPaneProps & {
  store: StoreApi<BuildOutputState>;
  workspaceId: string;
  scoped: boolean;
}) {
  const { t } = useTranslation();
  const session = useStore(store, (state) => state.sessions[sessionId] ?? null);
  const bindingRef = useRef<{ isCurrent: () => boolean } | null>(null);

  // Stream the bound operation's events into this workspace's store. The
  // identity reference only changes when a new operation begins, so the
  // subscription is re-created exactly then and on workspace switches.
  const identity = session?.identity ?? null;
  useEffect(() => {
    if (!identity) return;
    let closed = false;
    let release: (() => void) | undefined;
    let releaseStore = () => {};
    let releaseRegistry = () => {};
    const isCurrent = () =>
      !closed &&
      (scoped || workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId) &&
      workspaceRuntimeRegistry.getWorkspace(workspaceId)?.stores.get(BUILD_OUTPUT_STORE_KEY) ===
        store &&
      store.getState().sessions[sessionId]?.identity === identity;
    bindingRef.current = { isCurrent };
    const fail = (error: unknown) => {
      if (isCurrent())
        store.getState().actions.subscriptionFailed(sessionId, identity, failureMessage(error));
    };
    const close = () => {
      if (closed) return;
      closed = true;
      release?.();
      releaseStore();
      releaseRegistry();
    };
    // Invalidate at the owning-store boundary, before React's effect cleanup.
    // This also covers clear/rebind and workspace removal in a scoped panel.
    const checkBinding = () => {
      if (!isCurrent()) close();
    };
    releaseStore = store.subscribe(checkBinding);
    releaseRegistry = workspaceRuntimeRegistry.subscribe(checkBinding);
    if (managedEvents) return close;
    try {
      const acquisition = port.subscribe(identity, (event) => {
        if (!isCurrent()) return;
        const { actions } = store.getState();
        switch (event.type) {
          case "chunk":
            actions.appendChunk(sessionId, event, event.stream, event.text);
            break;
          case "diagnostics":
            actions.applyDiagnostics(sessionId, event, event.diagnostics);
            break;
          case "testResults":
            actions.applyTestResults(sessionId, event, event.results);
            break;
          case "terminal":
            actions.complete(sessionId, event, event.terminal);
            break;
        }
      });
      if (typeof acquisition === "function") {
        if (isCurrent()) release = acquisition;
        else acquisition();
      } else
        void acquisition.then((unsubscribe) => {
          if (!isCurrent()) unsubscribe();
          else release = unsubscribe;
        }, fail);
    } catch (error) {
      fail(error);
    }
    return close;
  }, [port, workspaceId, scoped, store, sessionId, identity, managedEvents]);

  // The stop control asks the port, which owns the operation, to cancel it.
  // Acceptance is not termination: only the owner's terminal event ends a run.
  const stop = useCallback(() => {
    const { actions, sessions } = store.getState();
    const current = sessions[sessionId];
    const binding = bindingRef.current;
    if (!current || !binding?.isCurrent() || !actions.beginStop(sessionId, current.identity))
      return;
    void Promise.resolve()
      .then(() => port.cancel(current.identity))
      .catch((error: unknown) => {
        if (binding.isCurrent())
          actions.stopFailed(sessionId, current.identity, failureMessage(error));
      });
  }, [port, store, sessionId]);

  const clear = useCallback(() => {
    useBuildOutputStore.getStore(workspaceId).getState().actions.clear(sessionId);
  }, [workspaceId, sessionId]);

  const reveal = useCallback(
    (path: string, line: number, column?: number) => {
      if (onReveal) {
        onReveal(path, line, column);
        return;
      }
      void useFileSystemStore
        .getStore(workspaceId)
        .getState()
        .handleFileSelect(path, false, line, column);
    },
    [onReveal, workspaceId],
  );

  const failedTests = useMemo(
    () =>
      (session?.testResults?.tests ?? []).filter(
        (test) => test.status === "failed" || test.status === "error",
      ),
    [session?.testResults],
  );

  return (
    <section
      aria-label={t("buildOutput.title")}
      className="flex h-full min-h-0 min-w-0 flex-col overflow-hidden bg-surface text-foreground"
    >
      <header className={paneHeaderClassName()}>
        <h2 className={cn(paneTitleClassName(), "min-w-0 truncate")}>{t("buildOutput.title")}</h2>
        {session && <RunStateLabel session={session} />}
        <span className="min-w-2 flex-1" />
        {session?.status === "running" && (
          <PaneIconButton
            type="button"
            aria-label={t("buildOutput.stopLabel")}
            title={t("buildOutput.stopLabel")}
            disabled={session.cancelling}
            onClick={stop}
          >
            <StopIcon className="size-3.5 text-warning" />
          </PaneIconButton>
        )}
        {session && (
          <PaneIconButton
            type="button"
            aria-label={t("buildOutput.clearLabel")}
            title={t("buildOutput.clearLabel")}
            onClick={clear}
          >
            <TrashIcon className="size-3.5" />
          </PaneIconButton>
        )}
        {onClose && (
          <PaneIconButton
            type="button"
            aria-label={t("buildOutput.close")}
            title={t("buildOutput.close")}
            onClick={onClose}
          >
            <XIcon className="size-3.5" />
          </PaneIconButton>
        )}
      </header>

      {session?.cancelError && (
        <p role="alert" className="border-b border-warning/40 px-2 py-1 text-xs text-warning">
          {t("buildOutput.stopFailed", { message: session.cancelError })}
        </p>
      )}
      {session?.subscriptionError && (
        <p
          role="alert"
          className="border-b border-border px-2 py-1 text-xs text-destructive break-words"
        >
          {t("buildOutput.subscriptionFailed", { message: session.subscriptionError })}
        </p>
      )}
      {session?.terminal?.message && (
        <p
          role={
            session.status === "failed" || session.status === "failedToStart" ? "alert" : "status"
          }
          className={cn(
            "border-b border-border px-2 py-1 text-xs",
            session.status === "failed" || session.status === "failedToStart"
              ? "text-destructive"
              : "text-warning",
          )}
        >
          {session.terminal.message}
        </p>
      )}

      {session ? (
        <>
          {session.testResults && (
            <BuildOutputTestsSummary results={session.testResults} dropped={session.testsDropped} />
          )}
          {(session.diagnostics.length > 0 ||
            failedTests.length > 0 ||
            session.diagnosticsDropped > 0) && (
            <BuildOutputProblems
              diagnostics={session.diagnostics}
              failedTests={failedTests}
              diagnosticsDropped={session.diagnosticsDropped}
              workspaceRoot={session.identity.workspaceRoot}
              onReveal={reveal}
            />
          )}
          <BuildOutputLog lines={session.lines} droppedLines={session.droppedLines} />
        </>
      ) : (
        <EmptyState message={t("buildOutput.emptyState")} />
      )}
    </section>
  );
}

function RunStateLabel({ session }: { session: BuildOutputSessionState }) {
  const { t } = useTranslation();
  const exitTitle = (base: string): string =>
    typeof session.terminal?.exitCode === "number"
      ? `${base} · ${t("buildOutput.exitCode", { code: session.terminal.exitCode })}`
      : base;
  switch (session.status) {
    case "running":
      return (
        <span className="inline-flex min-w-0 items-center gap-1 ui-text-sm text-muted-foreground">
          {session.cancelling ? null : <Spinner className="size-3" />}
          <span className="truncate">
            {session.cancelling ? t("buildOutput.stopping") : session.identity.title}
          </span>
        </span>
      );
    case "succeeded":
      return (
        <span
          title={exitTitle(t("buildOutput.status.succeeded"))}
          className="inline-flex items-center gap-1 ui-text-sm font-medium text-success"
        >
          <CheckCircleIcon className="size-3.5 shrink-0" />
          {t("buildOutput.status.succeeded")}
        </span>
      );
    case "failed":
      return (
        <span
          title={exitTitle(session.terminal?.message ?? t("buildOutput.status.failed"))}
          className="inline-flex items-center gap-1 ui-text-sm font-medium text-destructive"
        >
          <XCircleIcon className="size-3.5 shrink-0" />
          {t("buildOutput.status.failed")}
        </span>
      );
    case "cancelled":
      return (
        <span
          title={exitTitle(session.terminal?.message ?? t("buildOutput.status.cancelled"))}
          className="inline-flex items-center gap-1 ui-text-sm font-medium text-warning"
        >
          <StopIcon className="size-3.5 shrink-0" />
          {t("buildOutput.status.cancelled")}
        </span>
      );
    case "failedToStart":
      return (
        <span
          title={exitTitle(session.terminal?.message ?? t("buildOutput.status.failedToStart"))}
          className="inline-flex items-center gap-1 ui-text-sm font-medium text-destructive"
        >
          <XCircleIcon className="size-3.5 shrink-0" />
          {t("buildOutput.status.failedToStart")}
        </span>
      );
  }
}
