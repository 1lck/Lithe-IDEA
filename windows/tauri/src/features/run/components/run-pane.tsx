import { useEffect, useMemo, useState } from "react";
import { isBackendCapabilityAvailable } from "@/config/backend-capabilities";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { Button } from "@/ui/button";
import {
  ArrowClockwiseIcon,
  GearIcon,
  MinusIcon,
  PlayIcon,
  StopIcon,
  TrashIcon,
  WarningIcon,
  DotsThreeIcon,
} from "@/ui/icons";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import { ensureRunProcessListeners } from "../hooks/use-run-process-events";
import { runOptionsFor, useRunStore } from "../stores/run.store";
import { PRIMARY_SESSION_ID, type RunConfiguration } from "../types/run.types";
import {
  configurationsForExecution,
  blockingToolchainDiagnosticForConfiguration,
  workspaceRelativePath,
} from "../utils/run-configuration";
import { RunConfigurationEditor } from "./run-configuration-editor";
import { RunConfigurationListSplit } from "./run-configuration-list-split";
import { JavaCupIcon, RunIcon } from "./run-icon";
import { RunOutputText } from "./run-output-text";
import { useRunPreferencesStore } from "../stores/run-preferences.store";

export default function RunPane() {
  const { t } = useTranslation();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const activeFilePath = useBufferStore((state) => {
    const activeBuffer = getBufferById(state.buffers, state.activeBufferId);
    return activeBuffer?.type === "editor" && !activeBuffer.isVirtual ? activeBuffer.path : undefined;
  });
  const status = useRunStore((state) => state.status);
  const isLoading = useRunStore((state) => state.isLoading);
  const isGenerating = useRunStore((state) => state.isGenerating);
  const configurations = useRunStore((state) => state.configurations);
  const diagnostics = useRunStore((state) => state.diagnostics);
  const selectedConfigurationId = useRunStore((state) => state.selectedConfigurationId);
  const selectedSessionId = useRunStore((state) => state.selectedSessionId);
  const sessions = useRunStore((state) => state.sessions);
  const primaryOutput = useRunStore((state) => state.primaryOutput);
  const primaryRunning = useRunStore((state) => state.primaryRunning);
  const primaryTitle = useRunStore((state) => state.primaryTitle);
  const primaryExitCode = useRunStore((state) => state.primaryExitCode);
  const recoveryAction = useRunStore((state) => state.recoveryAction);
  const invalidMessage = useRunStore((state) => state.invalidMessage);
  const saveError = useRunStore((state) => state.saveError);
  const generationNotice = useRunStore((state) => state.generationNotice);
  const discoveredJava = useRunStore((state) => state.discoveredJava);
  const discoveredMaven = useRunStore((state) => state.discoveredMaven);
  const discoveredRuntimes = useRunStore((state) => state.discoveredRuntimes);
  const globalToolchain = useRunStore((state) => state.globalToolchain);
  const actions = useRunStore((state) => state.actions);
  const selectedServiceIDsByWorkspace = useRunPreferencesStore((state) => state.selectedServiceIDsByWorkspace);
  const setSelectedServiceIDs = useRunPreferencesStore((state) => state.actions.setSelectedServiceIDs);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [selectedServiceIDs, setSelectedServiceIDsLocal] = useState<string[]>([]);
  const [otherConfigurationsCollapsed, setOtherConfigurationsCollapsed] = useState(true);

  useEffect(() => {
    void ensureRunProcessListeners();
  }, []);

  useEffect(() => {
    if (!rootFolderPath || !isBackendCapabilityAvailable("run")) return;
    void actions.loadProject(rootFolderPath);
  }, [actions, rootFolderPath]);

  const services = useMemo(() => configurationsForExecution(configurations, "service"), [configurations]);
  const applications = useMemo(
    () => configurationsForExecution(configurations, "application"),
    [configurations],
  );
  const selectedConfiguration =
    configurations.find((configuration) => configuration.id === selectedConfigurationId) ?? null;
  const selectedSession = sessions.find((session) => session.id === selectedSessionId);
  const blockingDiagnostic = blockingToolchainDiagnosticForConfiguration(
    diagnostics,
    selectedConfiguration?.id,
  );
  const staleDiagnostic = diagnostics.find((diagnostic) => diagnostic.code === "staleFingerprint");
  const isSelectedRunning = selectedSession ? selectedSession.isRunning : primaryRunning;
  const output = selectedSession ? selectedSession.output : primaryOutput;
  const exitCode = selectedSession ? selectedSession.exitCode : primaryExitCode;
  const projectName =
    rootFolderPath?.split(/[\\/]/).filter(Boolean).pop() ?? t("run.title");
  const editingConfiguration = configurations.find((configuration) => configuration.id === editingId);
  const currentFile = activeFilePath && rootFolderPath
    ? workspaceRelativePath(rootFolderPath, activeFilePath)
    : undefined;
  useEffect(() => {
    if (!rootFolderPath || services.length === 0) {
      setSelectedServiceIDsLocal([]);
      return;
    }
    const saved = selectedServiceIDsByWorkspace[rootFolderPath];
    if (saved !== undefined) {
      setSelectedServiceIDsLocal(saved.filter((id) => services.some((service) => service.id === id)));
      return;
    }
    setSelectedServiceIDsLocal(services.slice(0, 1).map((service) => service.id));
  }, [rootFolderPath, selectedServiceIDsByWorkspace, services]);

  const updateSelectedServices = (ids: string[]) => {
    setSelectedServiceIDsLocal(ids);
    if (rootFolderPath) setSelectedServiceIDs(rootFolderPath, ids);
  };
  const runSelectedServices = () => {
    const ids = selectedServiceIDs.length > 0 ? selectedServiceIDs : services.map((service) => service.id);
    ids.forEach((id) => void actions.runConfiguration(id, currentFile));
  };
  const runAllServices = () => {
    services.forEach((service) => void actions.runConfiguration(service.id, currentFile));
  };

  const runSelected = () => {
    if (isSelectedRunning) {
      void actions.stop(selectedSession?.id);
      return;
    }
    const configuration = selectedConfiguration?.execution === "group"
      ? applications[0] ?? services[0]
      : selectedConfiguration ?? applications[0] ?? services[0];
    if (!configuration || !rootFolderPath) return;
    void actions.runConfiguration(configuration.id, currentFile);
  };

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <div className="flex h-(--lithe-pane-header-height) shrink-0 items-center gap-2 border-border/70 border-b px-3">
        <RunIcon className="size-4 text-subtle-foreground" />
        <div className="min-w-0 flex-1 truncate font-medium ui-text-sm">
          {t("run.title")} {projectName}
        </div>
        {isLoading ? <Spinner compact /> : null}
        {isSelectedRunning ? (
          <span className="text-success ui-text-sm">{t("run.running")}</span>
        ) : exitCode != null ? (
          <span className={exitCode === 0 ? "text-success ui-text-sm" : "text-destructive ui-text-sm"}>
            {exitCode === 0 ? t("run.succeeded") : t("run.failed")}
          </span>
        ) : null}
        <Tooltip content={isSelectedRunning ? t("run.stop") : t("run.run")} side="bottom">
          <Button variant="ghost" size="icon-xs" onClick={runSelected} disabled={isLoading} aria-label={t("run.run")}>
            {isSelectedRunning ? <StopIcon className="text-warning" /> : <PlayIcon className="text-success" />}
          </Button>
        </Tooltip>
        {services.length > 0 ? (
          <DropdownMenu>
            <DropdownMenuTrigger
              render={<Button variant="ghost" size="icon-xs" disabled={isLoading || isGenerating} aria-label={t("run.chooseServices")} />}
            >
              <DotsThreeIcon />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuLabel>{t("run.services")}</DropdownMenuLabel>
              {services.map((service) => (
                <DropdownMenuCheckboxItem
                  key={service.id}
                  checked={selectedServiceIDs.includes(service.id)}
                  onCheckedChange={(checked) =>
                    updateSelectedServices(
                      checked
                        ? [...selectedServiceIDs, service.id]
                        : selectedServiceIDs.filter((id) => id !== service.id),
                    )
                  }
                >
                  {service.name}
                </DropdownMenuCheckboxItem>
              ))}
              <DropdownMenuSeparator />
              <DropdownMenuItem disabled={isLoading || isGenerating || selectedServiceIDs.length === 0} onClick={runSelectedServices}>
                {t("run.runSelectedServices")}
              </DropdownMenuItem>
              <DropdownMenuItem disabled={isLoading || isGenerating} onClick={runAllServices}>{t("run.runAllServices")}</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        ) : null}
        <Tooltip content={t("run.rescan")} side="bottom">
          <Button
            variant="ghost"
            size="icon-xs"
            disabled={!rootFolderPath || isLoading}
            onClick={() => rootFolderPath && void actions.generate(rootFolderPath)}
            aria-label={t("run.rescan")}
          >
            <ArrowClockwiseIcon />
          </Button>
        </Tooltip>
        <Tooltip content={t("run.clearOutput")} side="bottom">
          <Button variant="ghost" size="icon-xs" onClick={() => actions.clearOutput()} aria-label={t("run.clearOutput")}>
            <TrashIcon />
          </Button>
        </Tooltip>
        <Tooltip content={t("run.minimize")} side="bottom">
          <Button
            variant="ghost"
            size="icon-xs"
            onClick={() => setIsBottomPaneVisible(false)}
            aria-label={t("run.minimize")}
          >
            <MinusIcon />
          </Button>
        </Tooltip>
      </div>

      {blockingDiagnostic || staleDiagnostic ? (
        <div className="flex items-start gap-2 border-warning/30 border-b bg-warning/10 px-3 py-2">
          <WarningIcon className="mt-0.5 size-3.5 text-warning" />
          <div className="min-w-0 flex-1">
            <div className="font-medium ui-text-sm">
              {blockingDiagnostic ? t("run.toolchainNeedsAttention") : t("run.staleConfigurations")}
            </div>
            <div className="text-subtle-foreground ui-text-sm">
              {blockingDiagnostic?.message ?? staleDiagnostic?.message}
            </div>
          </div>
          {blockingDiagnostic ? (
            <Button size="xs" onClick={() => selectedConfiguration && setEditingId(selectedConfiguration.id)}>
              {t("run.editService")}
            </Button>
          ) : (
            <Button size="xs" onClick={() => rootFolderPath && void actions.generate(rootFolderPath)}>
              {t("run.identifyAgain")}
            </Button>
          )}
        </div>
      ) : null}

      {status !== "ready" ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-3 px-6 text-center">
          <RunIcon className="size-8 text-subtle-foreground" />
          <div className="font-medium">{status === "missing" ? t("run.missingTitle") : t("run.invalidTitle")}</div>
          <div className="max-w-md text-subtle-foreground ui-text-sm">
            {status === "missing" ? t("run.missingMessage") : invalidMessage}
          </div>
          {recoveryAction !== "upgradeApplication" && recoveryAction !== "none" ? (
            <Button
              disabled={!rootFolderPath || isGenerating}
              onClick={() => rootFolderPath && void actions.generate(rootFolderPath)}
            >
              {isGenerating ? t("run.identifying") : t("run.identifyAndGenerate")}
            </Button>
          ) : null}
        </div>
      ) : (
        <RunConfigurationListSplit
          list={
            <>
              <div className="px-3 py-2 font-medium text-subtle-foreground ui-text-sm">
                {t("run.configurations")}
              </div>
              <div className="min-h-0 flex-1 overflow-y-auto pb-2">
                <ConfigurationSection
                  title={t("run.services")}
                  configurations={services}
                  selectedId={selectedConfigurationId}
                  sessions={sessions}
                  onSelect={actions.selectConfiguration}
                  onRun={(configuration) => void actions.runConfiguration(configuration.id, currentFile)}
                  onEdit={setEditingId}
                />
                <button
                  type="button"
                  className="mt-2 flex w-full items-center justify-between px-2 py-1 text-left font-medium text-subtle-foreground ui-text-sm hover:text-foreground"
                  onClick={() => setOtherConfigurationsCollapsed((collapsed) => !collapsed)}
                >
                  {t("run.otherConfigurations")}
                  <span aria-hidden>{otherConfigurationsCollapsed ? "▸" : "▾"}</span>
                </button>
                {!otherConfigurationsCollapsed ? (
                  <>
                    <ConfigurationSection
                      title={t("run.applications")}
                      configurations={applications}
                      selectedId={selectedConfigurationId}
                      sessions={sessions}
                      onSelect={actions.selectConfiguration}
                      onRun={(configuration) => void actions.runConfiguration(configuration.id, currentFile)}
                      onEdit={setEditingId}
                    />
                    <ConfigurationSection
                      title={t("run.tasks")}
                      configurations={configurationsForExecution(configurations, "task")}
                      selectedId={selectedConfigurationId}
                      sessions={sessions}
                      onSelect={actions.selectConfiguration}
                      onRun={(configuration) => void actions.runConfiguration(configuration.id, currentFile)}
                      onEdit={setEditingId}
                    />
                  </>
                ) : null}
              </div>
            </>
          }
          content={
            <>
              <div className="border-border/70 border-b px-3 py-2">
                <div className="font-medium text-subtle-foreground ui-text-sm">{t("run.configurationDetails")}</div>
                {selectedConfiguration ? (
                  <div className="mt-1 grid grid-cols-[6.5rem_1fr] gap-y-0.5 ui-text-sm">
                    <span className="text-subtle-foreground">{t("run.type")}</span>
                    <span>{selectedConfiguration.kindTitle}</span>
                    {selectedConfiguration.mainClass ? (
                      <>
                        <span className="text-subtle-foreground">{t("run.mainClass")}</span>
                        <span className="truncate font-mono">{selectedConfiguration.mainClass}</span>
                      </>
                    ) : null}
                  </div>
                ) : (
                  <div className="mt-1 text-subtle-foreground ui-text-sm">{t("run.selectConfiguration")}</div>
                )}
              </div>
              <div className="min-h-0 flex-1 overflow-auto px-3 py-2">
                <RunOutputText
                  title={t("run.processOutput")}
                  source={output}
                  emptyLabel={t("run.emptyOutput")}
                />
              </div>
              {isSelectedRunning ? (
                <RunStdinInput
                  sessionId={selectedSessionId ?? PRIMARY_SESSION_ID}
                  onSend={(input) => void actions.writeStdin(selectedSessionId ?? PRIMARY_SESSION_ID, input)}
                />
              ) : null}
              {generationNotice?.startsWith("generated:") ? (
                <div className="border-border/70 border-t px-3 py-1.5 text-subtle-foreground ui-text-sm">
                  {t("run.generatedEntries", { count: generationNotice.slice("generated:".length) })}
                </div>
              ) : null}
            </>
          }
        />
      )}

      {editingConfiguration ? (
        <RunConfigurationEditor
          configuration={editingConfiguration}
          options={runOptionsFor(editingConfiguration)}
          saveError={saveError}
          discoveredJava={discoveredJava}
          discoveredMaven={discoveredMaven}
          discoveredRuntimes={discoveredRuntimes}
          globalToolchain={globalToolchain}
          onClose={() => setEditingId(null)}
          onSave={(options, toolchain, scope) =>
            actions.saveEditorChanges(editingConfiguration, options, toolchain, scope)}
        />
      ) : null}
    </div>
  );
}

function RunStdinInput({
  sessionId,
  onSend,
}: {
  sessionId: string;
  onSend: (input: string) => void;
}) {
  const { t } = useTranslation();
  const [text, setText] = useState("");
  const submit = () => {
    const value = text.trim();
    if (!value) return;
    onSend(`${value}\n`);
    setText("");
  };
  return (
    <div className="flex items-center gap-1.5 border-border/70 border-t px-3 py-1.5">
      <input
        value={text}
        onChange={(event) => setText(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") submit();
        }}
        placeholder={t("run.stdinPlaceholder")}
        className="h-7 min-w-0 flex-1 rounded-md border border-input bg-transparent px-2 font-mono text-[12px] text-foreground outline-none focus-visible:border-ring"
        aria-label={t("run.stdinPlaceholder")}
      />
      <Button size="xs" variant="accent" onClick={submit} disabled={!text.trim()}>
        {t("run.stdinSend")}
      </Button>
    </div>
  );
}

function ConfigurationSection({
  title,
  configurations,
  selectedId,
  sessions,
  onSelect,
  onRun,
  onEdit,
}: {
  title: string;
  configurations: RunConfiguration[];
  selectedId: string | null;
  sessions: Array<{ id: string; isRunning: boolean }>;
  onSelect: (id: string) => void;
  onRun: (configuration: RunConfiguration) => void;
  onEdit: (id: string) => void;
}) {
  const { t } = useTranslation();
  if (configurations.length === 0) return null;
  return (
    <section className="px-1">
      <div className="px-2 py-1 font-medium text-subtle-foreground ui-text-sm">{title}</div>
      {configurations.map((configuration) => {
        const running = sessions.some((session) => session.id === configuration.id && session.isRunning);
        return (
          <div
            key={configuration.id}
            className={cn(
              "group flex items-center gap-1 rounded-md px-1.5 py-1 ui-text-sm",
              selectedId === configuration.id ? "bg-selected text-foreground" : "hover:bg-accent",
            )}
          >
            <button
              type="button"
              className="flex min-w-0 flex-1 items-center gap-1.5 text-left"
              onClick={() => onSelect(configuration.id)}
            >
              <JavaCupIcon className="shrink-0 text-subtle-foreground" />
              <span className="min-w-0 truncate">{configuration.name}</span>
            </button>
            <Button
              variant="ghost"
              size="icon-xs"
              className="opacity-0 group-hover:opacity-100"
              onClick={() => onEdit(configuration.id)}
              aria-label={t("ui.edit")}
            >
              <GearIcon />
            </Button>
            <Button
              variant="ghost"
              size="icon-xs"
              onClick={() => onRun(configuration)}
              aria-label={t("run.title")}
            >
              {running ? <StopIcon className="text-warning" /> : <PlayIcon className="text-success" />}
            </Button>
          </div>
        );
      })}
    </section>
  );
}
