import { useEffect, useSyncExternalStore } from "react";
import { useShallow } from "zustand/react/shallow";
import { isBackendCapabilityAvailable } from "@/config/backend-capabilities";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { CaretDownIcon, BugIcon, ArrowClockwiseIcon, PlayIcon, StopIcon } from "@/ui/icons";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import { useRunStore } from "../stores/run.store";
import { ensureRunProcessListeners } from "../hooks/use-run-process-events";
import { blockingToolchainDiagnosticForConfiguration } from "../utils/run-configuration";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  canDebugConfiguration,
  ownsSelectedDebug,
  selectedRunExecution,
  startSelectedRunConfiguration,
  stopSelectedRunConfiguration,
  useRunControlState,
} from "../actions/selected-run-actions";
import { RunConfigurationIcon } from "./run-icon";

/** Presentation over the existing workspace Run owner; no second entrypoint discovery. */
export function TitleRunControl() {
  const { t } = useTranslation();
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const state = useRunStore(
    useShallow((current) => ({
      root: current.root,
      configurations: current.configurations,
      selectedConfigurationId: current.selectedConfigurationId,
      isLoading: current.isLoading,
      isGenerating: current.isGenerating,
      diagnostics: current.diagnostics,
      actions: current.actions,
      javaDiscovery: current.javaDiscovery,
      javaDiscoveryMessage: current.javaDiscoveryMessage,
    })),
  );
  const execution = useRunStore(
    useShallow((current) => selectedRunExecution(current, current.selectedConfigurationId)),
  );
  const workspaceId = useSyncExternalStore(
    workspaceRuntimeRegistry.subscribe,
    workspaceRuntimeRegistry.getActiveWorkspaceId,
  );
  const operation = useRunControlState((current) => current.operations[workspaceId]);
  const error = useRunControlState((current) => current.errors[workspaceId]);
  const debugSession = useDebuggerStore((current) => current.activeSession);
  const activeFile = useBufferStore((current) => {
    const buffer = getBufferById(current.buffers, current.activeBufferId);
    return buffer?.type === "editor" && !buffer.isVirtual ? buffer.path : undefined;
  });
  const openSettings = useUIState((current) => current.openSettingsDialog);
  useEffect(() => {
    if (!root || !isBackendCapabilityAvailable("run")) return;
    const current = useRunStore.getState();
    if (current.root !== root || (current.status === "missing" && !current.isLoading))
      void current.actions.loadProject(root);
    void ensureRunProcessListeners().catch((error) =>
      console.error("Run event listeners unavailable", error),
    );
  }, [root]);
  if (!root || !isBackendCapabilityAvailable("run")) return null;
  const configurations =
    state.root === root ? state.configurations.filter((entry) => entry.execution !== "group") : [];
  const selected =
    configurations.find((entry) => entry.id === state.selectedConfigurationId) ?? null;
  const loading = state.isLoading || state.isGenerating;
  const debugging = ownsSelectedDebug(debugSession, workspaceId, selected?.id ?? null);
  const preparing = execution.preparing || !!operation;
  const stoppingAvailable =
    !!selected &&
    (execution.running ||
      execution.preparing ||
      debugging ||
      operation?.configurationId === selected.id);
  const otherDebug = !!debugSession && debugSession.status !== "idle" && !debugging;
  const blocked =
    selected && blockingToolchainDiagnosticForConfiguration(state.diagnostics, selected.id);
  const edit = () => {
    state.actions.editConfiguration(selected?.id ?? null);
    openSettings("run");
  };
  const launchDisabled =
    !selected ||
    selected.disabled ||
    loading ||
    preparing ||
    !!blocked ||
    (selected.provider === "java.current-file" && !activeFile);
  const discoveryMessage =
    state.javaDiscovery === "failed"
      ? (state.javaDiscoveryMessage ?? t("run.javaDiscoveryFailed", { message: "" }))
      : state.javaDiscovery === "loading" || state.javaDiscovery === "stale"
        ? t("run.javaDiscoveryLoading")
        : undefined;
  return (
    <div className="flex min-w-0 items-center gap-1" data-testid="title-run-control">
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              variant="ghost"
              size="xs"
              className="w-52 max-w-[24vw] min-w-0 justify-start"
              aria-label={t("javaRun.chooseRun")}
              title={discoveryMessage}
            />
          }
        >
          {loading ? (
            <Spinner compact />
          ) : selected ? (
            <RunConfigurationIcon provider={selected.provider} iconKey={selected.iconKey} />
          ) : (
            <PlayIcon />
          )}
          <span className="min-w-0 flex-1 truncate">
            {selected?.name ?? t(loading ? "run.identifying" : "run.configurations")}
          </span>
          <CaretDownIcon />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          {configurations.map((entry) => (
            <DropdownMenuItem
              key={entry.id}
              disabled={entry.disabled || !!operation}
              onClick={() => state.actions.selectConfiguration(entry.id)}
            >
              <RunConfigurationIcon provider={entry.provider} iconKey={entry.iconKey} />
              <span>{entry.name}</span>
            </DropdownMenuItem>
          ))}
          <DropdownMenuSeparator />
          <DropdownMenuItem disabled={loading} onClick={() => void state.actions.generate(root)}>
            {t("run.identifyAndGenerate")}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={edit}>{t("javaRun.editRun")}</DropdownMenuItem>
          {discoveryMessage && (
            <div role="status" className="max-w-80 px-2 py-1 ui-text-sm text-muted-foreground">
              {discoveryMessage}
            </div>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={t(execution.running && !debugging ? "javaRun.rerun" : "run.run")}
        tooltip={
          blocked?.message ?? t(execution.running && !debugging ? "javaRun.rerun" : "run.run")
        }
        disabled={launchDisabled}
        onClick={() => void startSelectedRunConfiguration("run")}
      >
        {operation?.mode === "run" ? (
          <Spinner compact />
        ) : execution.running && !debugging ? (
          <ArrowClockwiseIcon className="text-success" />
        ) : (
          <PlayIcon className="text-success" />
        )}
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={t(debugging ? "javaRun.redebug" : "javaRun.debug")}
        tooltip={
          !canDebugConfiguration(selected)
            ? t("javaRun.debugUnavailable")
            : otherDebug
              ? t("javaRun.otherDebug")
              : t(debugging ? "javaRun.redebug" : "javaRun.debug")
        }
        disabled={launchDisabled || !canDebugConfiguration(selected) || otherDebug}
        onClick={() => void startSelectedRunConfiguration("debug")}
      >
        {operation?.mode === "debug" ? <Spinner compact /> : <BugIcon className="text-success" />}
      </Button>
      {stoppingAvailable && (
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={t("run.stop")}
          tooltip={t("run.stop")}
          onClick={() => void stopSelectedRunConfiguration()}
        >
          <StopIcon className="text-destructive" />
        </Button>
      )}
      {error && (
        <span role="alert" title={error} className="max-w-40 truncate ui-text-sm text-destructive">
          {error}
        </span>
      )}
    </div>
  );
}
