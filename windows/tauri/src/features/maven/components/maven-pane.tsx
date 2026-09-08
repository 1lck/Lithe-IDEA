import { useEffect, useMemo, useState, type ReactNode } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceScopeMatchesRoot } from "@/features/workspace/types/workspace-launch-scope";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import Dialog from "@/ui/dialog";
import Input from "@/ui/input";
import {
  ArrowClockwiseIcon,
  ArrowCounterClockwiseIcon,
  ArrowsInIcon,
  CaretDownIcon,
  CaretRightIcon,
  FolderIcon,
  GearIcon,
  PackageIcon,
  PlayIcon,
  PlusIcon,
  SlidersHorizontalIcon,
  StopIcon,
  TerminalIcon,
  TrashIcon,
  WarningIcon,
  XIcon,
} from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import { Spinner } from "@/ui/spinner";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import { joinPath } from "@/utils/path-helpers";
import { openMavenRunPane } from "../actions/maven-tool-window-actions";
import { ensureMavenProcessListeners } from "../hooks/use-maven-process-events";
import { availableMavenProfiles, useMavenStore } from "../stores/maven.store";
import {
  reloadJavaForMavenWorkspace,
  reloadMavenWorkspaceProjects,
} from "../services/reload-maven-workspace";
import {
  MAVEN_LIFECYCLE_PHASES,
  type MavenDependency,
  type MavenLifecyclePhase,
  type MavenModule,
  type MavenSettings,
} from "../types/maven.types";
import { MavenSourceRootRows } from "./maven-source-root-rows";

interface TreeNodeProps {
  id: string;
  title: string;
  subtitle?: string;
  icon?: ReactNode;
  selected?: boolean;
  expanded: boolean;
  onToggle: (id: string) => void;
  onSelect?: () => void;
  children?: ReactNode;
}

interface MavenPaneProps {
  onClose: () => void;
}

function TreeNode({
  id,
  title,
  subtitle,
  icon,
  selected,
  expanded,
  onToggle,
  onSelect,
  children,
}: TreeNodeProps) {
  const hasChildren = children !== undefined && children !== null;
  return (
    <div>
      <div className={cn("flex min-h-7 items-center rounded-sm", selected && "bg-selected")}>
        {hasChildren ? (
          <button
            type="button"
            className="flex size-6 shrink-0 items-center justify-center text-subtle-foreground"
            onClick={() => onToggle(id)}
            aria-label={expanded ? "Collapse" : "Expand"}
          >
            {expanded ? (
              <CaretDownIcon className="size-3" />
            ) : (
              <CaretRightIcon className="size-3" />
            )}
          </button>
        ) : (
          <span className="size-6 shrink-0" />
        )}
        <button
          type="button"
          className="flex min-w-0 flex-1 items-center gap-1.5 py-1 pr-2 text-left"
          onClick={onSelect ?? (() => onToggle(id))}
        >
          <span className="shrink-0 text-primary">
            {icon ?? <PackageIcon className="size-3.5" />}
          </span>
          <span className="min-w-0 truncate ui-text-sm">{title}</span>
          {subtitle ? (
            <span className="min-w-0 truncate font-mono text-subtle-foreground ui-text-xs">
              {subtitle}
            </span>
          ) : null}
        </button>
      </div>
      {expanded && hasChildren ? (
        <div className="ml-4 border-border/60 border-l pl-1">{children}</div>
      ) : null}
    </div>
  );
}

function MavenSettingsDialog({
  initial,
  error,
  onClose,
  onSave,
}: {
  initial: MavenSettings;
  error: string | null;
  onClose: () => void;
  onSave: (settings: MavenSettings) => void;
}) {
  const { t } = useTranslation();
  const [draft, setDraft] = useState(initial);

  const choosePath = async (field: keyof MavenSettings, directory: boolean) => {
    const selected = await open({
      directory,
      multiple: false,
      ...(field === "settingsPath"
        ? { filters: [{ name: "Maven settings", extensions: ["xml"] }] }
        : {}),
    });
    if (typeof selected === "string") setDraft((current) => ({ ...current, [field]: selected }));
  };

  const fields: Array<{
    id: string;
    field: keyof MavenSettings;
    label: string;
    directory: boolean;
  }> = [
    { id: "maven-settings-xml", field: "settingsPath", label: "settings.xml", directory: false },
    {
      id: "maven-local-repository",
      field: "localRepositoryPath",
      label: t("maven.localRepository"),
      directory: true,
    },
    {
      id: "maven-executable",
      field: "mavenExecutablePath",
      label: t("maven.mavenExecutable"),
      directory: true,
    },
    {
      id: "maven-jdk-home",
      field: "javaHomePath",
      label: t("maven.javaHome"),
      directory: true,
    },
  ];

  return (
    <Dialog
      title={t("maven.settings")}
      icon={SlidersHorizontalIcon}
      onClose={onClose}
      size="lg"
      footer={
        <>
          {error ? (
            <span className="min-w-0 flex-1 truncate text-destructive ui-text-sm">{error}</span>
          ) : (
            <span />
          )}
          <Button variant="ghost" onClick={onClose}>
            {t("ui.cancel")}
          </Button>
          <Button
            onClick={() => {
              onSave(draft);
              onClose();
            }}
          >
            {t("ui.save")}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        {fields.map(({ id, field, label, directory }) => (
          <label key={field} htmlFor={id} className="block space-y-1.5">
            <span className="font-medium ui-text-sm">{label}</span>
            <div className="flex gap-2">
              <Input
                id={id}
                value={draft[field]}
                placeholder={t("maven.automatic")}
                onChange={(event) =>
                  setDraft((current) => ({ ...current, [field]: event.target.value }))
                }
              />
              <Tooltip content={t("ui.clear")}>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  onClick={() => setDraft((current) => ({ ...current, [field]: "" }))}
                  aria-label={t("ui.clear")}
                >
                  <TrashIcon />
                </Button>
              </Tooltip>
              <Tooltip content={t("ui.browse")}>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  onClick={() => void choosePath(field, directory)}
                  aria-label={t("ui.browse")}
                >
                  <FolderIcon />
                </Button>
              </Tooltip>
            </div>
          </label>
        ))}
      </div>
    </Dialog>
  );
}

export default function MavenPane({ onClose }: MavenPaneProps) {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const root = useMavenStore((state) => state.root);
  const visiblePaths = useMavenStore((state) => state.visiblePaths);
  const projectStatus = useMavenStore((state) => state.projectStatus);
  const projectError = useMavenStore((state) => state.projectError);
  const project = useMavenStore((state) => state.project);
  const selectedProfiles = useMavenStore((state) => state.selectedProfiles);
  const customProfiles = useMavenStore((state) => state.customProfiles);
  const skipTests = useMavenStore((state) => state.skipTests);
  const settingsPath = useMavenStore((state) => state.settingsPath);
  const localRepositoryPath = useMavenStore((state) => state.localRepositoryPath);
  const mavenExecutablePath = useMavenStore((state) => state.mavenExecutablePath);
  const javaHomePath = useMavenStore((state) => state.javaHomePath);
  const configurationSaveError = useMavenStore((state) => state.configurationSaveError);
  const reloadRequired = useMavenStore((state) => state.reloadRequired);
  const taskStatus = useMavenStore((state) => state.taskStatus);
  const taskError = useMavenStore((state) => state.taskError);
  const output = useMavenStore((state) => state.output);
  const issues = useMavenStore((state) => state.issues);
  const lastExitCode = useMavenStore((state) => state.lastExitCode);
  const dependencyLoads = useMavenStore((state) => state.dependencyLoads);
  const actions = useMavenStore((state) => state.actions);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const [selectedModule, setSelectedModule] = useState<string | null>(null);
  const [selectedPhase, setSelectedPhase] = useState<MavenLifecyclePhase>("compile");
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [goalDialogOpen, setGoalDialogOpen] = useState(false);
  const [settingsDialogOpen, setSettingsDialogOpen] = useState(false);
  const [profileDialogOpen, setProfileDialogOpen] = useState(false);
  const [customGoal, setCustomGoal] = useState("");
  const [customProfile, setCustomProfile] = useState("");
  const [reloadError, setReloadError] = useState<string | null>(null);

  const profiles = useMemo(
    () => availableMavenProfiles({ project, customProfiles }),
    [customProfiles, project],
  );
  const isRunning = taskStatus === "running" || taskStatus === "stopping";

  useEffect(() => {
    void ensureMavenProcessListeners();
  }, []);

  useEffect(() => {
    setReloadError(null);
  }, [root, workspaceId]);

  useEffect(() => {
    if (!project) return;
    const initial = new Set<string>([`project:${project.relativePath}`]);
    if (profiles.length > 0) initial.add("profiles");
    setExpanded(initial);
    setSelectedModule(null);
    setSelectedPhase("compile");
  }, [project?.relativePath]);

  const toggleExpanded = (id: string) => {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const runPhase = (phase: MavenLifecyclePhase, module: MavenModule | null) => {
    setSelectedModule(module?.relativePath ?? null);
    setSelectedPhase(phase);
    const target = module?.artifactId ?? project?.artifactId ?? t("maven.project");
    openMavenRunPane();
    void actions.runGoals([phase], module?.relativePath ?? null, `${phase} · ${target}`);
  };

  const runSelected = () => {
    const module = findMavenModule(project?.modules ?? [], selectedModule);
    runPhase(selectedPhase, module);
  };

  const runCustomGoal = () => {
    const goals = customGoal.trim().split(/\s+/).filter(Boolean);
    if (goals.length === 0) return;
    const module = findMavenModule(project?.modules ?? [], selectedModule);
    const target = module?.artifactId ?? project?.artifactId ?? t("maven.project");
    setGoalDialogOpen(false);
    openMavenRunPane();
    void actions.runGoals(goals, module?.relativePath ?? null, `${customGoal.trim()} · ${target}`);
  };

  const reloadJava = async () => {
    if (!root) return;
    const scope = { workspaceId, root };
    setReloadError(null);
    try {
      await reloadJavaForMavenWorkspace(scope);
    } catch (error) {
      if (
        workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId &&
        workspaceScopeMatchesRoot(scope, useMavenStore.getStore(workspaceId).getState().root)
      ) {
        setReloadError(error instanceof Error ? error.message : t("maven.reloadFailed"));
      }
    }
  };

  const reloadProjects = async () => {
    if (!root) return;
    const scope = { workspaceId, root };
    setReloadError(null);
    try {
      await reloadMavenWorkspaceProjects(scope);
    } catch (error) {
      if (
        workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId &&
        workspaceScopeMatchesRoot(scope, useMavenStore.getStore(workspaceId).getState().root)
      ) {
        setReloadError(error instanceof Error ? error.message : t("maven.reloadFailed"));
      }
    }
  };

  const renderSourceRoots = (ownerId: string, sourceRoots: MavenModule["sourceRoots"]) => {
    if (sourceRoots.length === 0) return null;
    const id = `${ownerId}:source-roots`;
    return (
      <TreeNode
        id={id}
        title={t("maven.sourceRoots")}
        icon={<FolderIcon className="size-3.5" />}
        expanded={expanded.has(id)}
        onToggle={toggleExpanded}
      >
        <MavenSourceRootRows sourceRoots={sourceRoots} />
      </TreeNode>
    );
  };

  const openModulePom = (modulePath: string) => {
    if (!root || !project) return;
    const path = joinPath(
      root,
      project.relativePath === "." ? "" : project.relativePath,
      modulePath === "." ? "" : modulePath,
      "pom.xml",
    );
    void handleFileSelect(path, false, undefined, undefined, undefined, false);
  };

  const renderDependency = (dependency: MavenDependency, id: string): ReactNode => {
    const marker =
      dependency.resolution === "omittedConflict"
        ? `${t("maven.omittedConflict")}${dependency.selectedVersion ? ` -> ${dependency.selectedVersion}` : ""}`
        : dependency.resolution === "omittedDuplicate"
          ? t("maven.omittedDuplicate")
          : null;
    const classifier = dependency.classifier ? `:${dependency.classifier}` : "";
    const subtitle = `${dependency.groupId}:${dependency.version}:${dependency.type}${classifier} [${dependency.scope}]${marker ? ` (${marker})` : ""}`;
    const children =
      dependency.children.length > 0
        ? dependency.children.map((child, index) =>
            renderDependency(child, `${id}:${child.groupId}:${child.artifactId}:${index}`),
          )
        : undefined;
    return (
      <TreeNode
        key={id}
        id={id}
        title={dependency.artifactId}
        subtitle={subtitle}
        icon={
          dependency.resolution === "resolved" ? (
            <PackageIcon className="size-3.5" />
          ) : (
            <WarningIcon className="size-3.5 text-warning" />
          )
        }
        expanded={expanded.has(id)}
        onToggle={toggleExpanded}
        onSelect={() => openModulePom(dependency.modulePath)}
      >
        {children}
      </TreeNode>
    );
  };

  const renderDependencies = (ownerId: string, modulePath: string) => {
    const id = `${ownerId}:dependencies`;
    const load = dependencyLoads[modulePath] ?? {
      status: "idle" as const,
      dependencies: [],
      error: null,
    };
    const toggle = () => {
      const shouldLoad = !expanded.has(id);
      toggleExpanded(id);
      if (shouldLoad) void actions.loadDependencies(modulePath);
    };
    return (
      <TreeNode
        id={id}
        title={t("maven.dependencies")}
        icon={<PackageIcon className="size-3.5" />}
        expanded={expanded.has(id)}
        onToggle={toggle}
      >
        {load.status === "loading" ? (
          <div className="flex min-h-8 items-center gap-2 px-2 text-subtle-foreground ui-text-sm">
            <Spinner compact />
            <span className="min-w-0 flex-1 truncate">{t("maven.dependencyLoading")}</span>
            <Button
              size="xs"
              variant="ghost"
              onClick={() => void actions.cancelDependencies(modulePath)}
            >
              {t("ui.cancel")}
            </Button>
          </div>
        ) : load.status === "failed" ? (
          <div className="space-y-1 px-2 py-1.5">
            <div className="flex items-start gap-1.5 text-destructive ui-text-sm">
              <WarningIcon className="mt-0.5 size-3.5 shrink-0" />
              <span className="min-w-0 break-words">{load.error}</span>
            </div>
            <Button size="xs" variant="ghost" onClick={() => void actions.loadDependencies(modulePath)}>
              {t("ui.retry")}
            </Button>
          </div>
        ) : load.status === "cancelled" ? (
          <div className="flex min-h-8 items-center gap-2 px-2 text-warning ui-text-sm">
            <span className="min-w-0 flex-1 truncate">{t("maven.dependencyCancelled")}</span>
            <Button size="xs" variant="ghost" onClick={() => void actions.loadDependencies(modulePath)}>
              {t("ui.retry")}
            </Button>
          </div>
        ) : load.status === "ready" && load.dependencies.length === 0 ? (
          <div className="px-2 py-1.5 text-subtle-foreground ui-text-sm">
            {t("maven.noDependencies")}
          </div>
        ) : (
          load.dependencies.map((dependency, index) =>
            renderDependency(
              dependency,
              `${id}:${dependency.groupId}:${dependency.artifactId}:${index}`,
            ),
          )
        )}
      </TreeNode>
    );
  };

  const renderLifecycle = (ownerId: string, module: MavenModule | null) => {
    const id = `${ownerId}:lifecycle`;
    return (
      <TreeNode
        id={id}
        title={t("maven.lifecycle")}
        icon={<GearIcon className="size-3.5" />}
        expanded={expanded.has(id)}
        onToggle={toggleExpanded}
      >
        {MAVEN_LIFECYCLE_PHASES.map((phase) => {
          const selected =
            selectedModule === (module?.relativePath ?? null) && selectedPhase === phase;
          return (
            <button
              key={phase}
              type="button"
              className={cn(
                "flex h-7 w-full items-center gap-1.5 rounded-sm px-2 text-left ui-text-sm",
                selected ? "bg-selected text-foreground" : "text-subtle-foreground hover:bg-hover",
              )}
              onClick={() => {
                setSelectedModule(module?.relativePath ?? null);
                setSelectedPhase(phase);
              }}
              onDoubleClick={() => !isRunning && runPhase(phase, module)}
            >
              <PlayIcon className={cn("size-3", selected && "text-success")} />
              <span className="truncate">{phase}</span>
            </button>
          );
        })}
      </TreeNode>
    );
  };

  const renderModule = (module: MavenModule): ReactNode => {
    const id = `module:${module.relativePath}`;
    return (
      <TreeNode
        key={id}
        id={id}
        title={module.artifactId}
        subtitle={module.relativePath}
        selected={selectedModule === module.relativePath}
        expanded={expanded.has(id)}
        onToggle={toggleExpanded}
        onSelect={() => setSelectedModule(module.relativePath)}
      >
        {renderSourceRoots(id, module.sourceRoots)}
        {renderLifecycle(id, module)}
        {renderDependencies(id, module.relativePath)}
        {module.modules.map(renderModule)}
      </TreeNode>
    );
  };

  return (
    <section aria-label={t("maven.title")} className="flex h-full min-h-0 flex-col bg-background">
      <div className="shrink-0 border-border/70 border-b">
        <div className="flex h-8 min-w-0 items-center gap-2 overflow-hidden px-3">
          <PackageIcon className="size-4 shrink-0 text-primary" />
          <div className="min-w-0 flex-1 truncate font-medium ui-text-sm">
            {t("maven.title")}
            {project ? ` · ${project.artifactId}` : ""}
          </div>
          {projectStatus === "loading" ? <Spinner compact /> : null}
          <Tooltip content={t("commandPalette.close")}>
            <Button
              variant="ghost"
              size="icon-xs"
              className="shrink-0"
              onClick={onClose}
              aria-label={t("commandPalette.close")}
            >
              <XIcon />
            </Button>
          </Tooltip>
        </div>
        <div className="scrollbar-none flex h-8 min-w-0 overflow-x-auto px-2">
          <div className="flex min-w-max items-center gap-1">
            <Tooltip content={isRunning ? t("maven.stop") : t("maven.runSelected")}>
              <Button
                variant="ghost"
                size="icon-xs"
                disabled={!project}
                onClick={isRunning ? () => void actions.stop() : runSelected}
                aria-label={isRunning ? t("maven.stop") : t("maven.runSelected")}
              >
                {isRunning ? (
                  <StopIcon className="text-warning" />
                ) : (
                  <PlayIcon className="text-success" />
                )}
              </Button>
            </Tooltip>
            <Tooltip content={t("maven.executeGoal")}>
              <Button
                variant="ghost"
                size="icon-xs"
                disabled={!project || isRunning}
                onClick={() => {
                  setCustomGoal("");
                  setGoalDialogOpen(true);
                }}
                aria-label={t("maven.executeGoal")}
              >
                <TerminalIcon />
              </Button>
            </Tooltip>
            <Tooltip content={t("maven.reloadProjects")}>
              <Button
                variant="ghost"
                size="icon-xs"
                disabled={!root || isRunning || projectStatus === "loading"}
                onClick={() => void reloadProjects()}
                aria-label={t("maven.reloadProjects")}
              >
                <ArrowClockwiseIcon />
              </Button>
            </Tooltip>
            <Tooltip content={t("maven.skipTests")}>
              <Checkbox
                checked={skipTests}
                disabled={!project}
                onCheckedChange={actions.setSkipTests}
                aria-label={t("maven.skipTests")}
                className="mx-1"
              />
            </Tooltip>
            <Tooltip content={t("maven.collapseAll")}>
              <Button
                variant="ghost"
                size="icon-xs"
                onClick={() => setExpanded(new Set())}
                aria-label={t("maven.collapseAll")}
              >
                <ArrowsInIcon />
              </Button>
            </Tooltip>
            <Tooltip content={t("maven.settings")}>
              <Button
                variant="ghost"
                size="icon-xs"
                disabled={!project}
                onClick={() => setSettingsDialogOpen(true)}
                aria-label={t("maven.settings")}
              >
                <SlidersHorizontalIcon />
              </Button>
            </Tooltip>
          </div>
        </div>
      </div>

      {reloadRequired || configurationSaveError || reloadError ? (
        <div className="flex min-h-9 shrink-0 items-center gap-2 border-border/70 border-b bg-warning/10 px-3">
          <WarningIcon className="size-3.5 text-warning" />
          <span className="min-w-0 flex-1 truncate ui-text-sm">
            {configurationSaveError ?? reloadError ?? t("maven.configurationChanged")}
          </span>
          {reloadRequired || reloadError ? (
            <Button size="xs" variant="ghost" onClick={() => void reloadJava()}>
              {t("maven.reloadJdt")}
            </Button>
          ) : null}
        </div>
      ) : null}

      {projectStatus === "failed" ? (
        <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
          <WarningIcon className="size-7 text-destructive" />
          <div className="font-medium">{t("maven.loadFailed")}</div>
          <div className="max-w-lg text-subtle-foreground ui-text-sm">{projectError}</div>
          <Button size="sm" onClick={() => root && void actions.loadProject(root, visiblePaths)}>
            {t("ui.retry")}
          </Button>
        </div>
      ) : project ? (
        <div className="flex min-h-0 flex-1 flex-col">
          <ScrollArea className="min-h-0 flex-1 bg-sidebar" reserveScrollbarGutter>
            <div className="space-y-0.5 p-2">
              {profiles.length > 0 ? (
                <TreeNode
                  id="profiles"
                  title={t("maven.profiles")}
                  icon={<FolderIcon className="size-3.5" />}
                  expanded={expanded.has("profiles")}
                  onToggle={toggleExpanded}
                >
                  <div className="flex h-7 items-center gap-1 px-1">
                    <Tooltip content={t("maven.addProfile")}>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        onClick={() => {
                          setCustomProfile("");
                          setProfileDialogOpen(true);
                        }}
                        aria-label={t("maven.addProfile")}
                      >
                        <PlusIcon />
                      </Button>
                    </Tooltip>
                    <Tooltip content={t("maven.restoreProfiles")}>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        onClick={actions.restoreDefaultProfiles}
                        aria-label={t("maven.restoreProfiles")}
                      >
                        <ArrowCounterClockwiseIcon />
                      </Button>
                    </Tooltip>
                  </div>
                  {profiles.map((profile) => (
                    <label
                      key={profile.id}
                      className="flex h-7 cursor-pointer items-center gap-2 rounded-sm px-2 hover:bg-hover"
                    >
                      <Checkbox
                        checked={selectedProfiles.includes(profile.id)}
                        onCheckedChange={(checked) =>
                          actions.setSelectedProfiles(
                            checked
                              ? [...selectedProfiles, profile.id]
                              : selectedProfiles.filter((value) => value !== profile.id),
                          )
                        }
                      />
                      <span className="min-w-0 truncate ui-text-sm">{profile.id}</span>
                    </label>
                  ))}
                </TreeNode>
              ) : null}
              <TreeNode
                id={`project:${project.relativePath}`}
                title={project.artifactId}
                subtitle={project.packaging}
                selected={selectedModule === null}
                expanded={expanded.has(`project:${project.relativePath}`)}
                onToggle={toggleExpanded}
                onSelect={() => setSelectedModule(null)}
              >
                {renderSourceRoots(`project:${project.relativePath}`, project.sourceRoots)}
                {renderLifecycle(`project:${project.relativePath}`, null)}
                {renderDependencies(`project:${project.relativePath}`, ".")}
                {project.modules.map(renderModule)}
              </TreeNode>
            </div>
          </ScrollArea>
        </div>
      ) : (
        <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground ui-text-sm">
          {projectStatus === "loading" ? t("maven.scanning") : t("maven.notDetected")}
        </div>
      )}

      {goalDialogOpen ? (
        <Dialog
          title={t("maven.executeGoal")}
          icon={TerminalIcon}
          onClose={() => setGoalDialogOpen(false)}
          footer={
            <>
              <Button variant="ghost" onClick={() => setGoalDialogOpen(false)}>
                {t("ui.cancel")}
              </Button>
              <Button disabled={!customGoal.trim()} onClick={runCustomGoal}>
                {t("run.run")}
              </Button>
            </>
          }
        >
          <Input
            autoFocus
            value={customGoal}
            placeholder="spring-boot:run"
            onChange={(event) => setCustomGoal(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") runCustomGoal();
            }}
          />
        </Dialog>
      ) : null}
      {profileDialogOpen ? (
        <Dialog
          title={t("maven.addProfile")}
          icon={PlusIcon}
          onClose={() => setProfileDialogOpen(false)}
          footer={
            <>
              <Button variant="ghost" onClick={() => setProfileDialogOpen(false)}>
                {t("ui.cancel")}
              </Button>
              <Button
                disabled={!customProfile.trim()}
                onClick={() => {
                  if (actions.addCustomProfile(customProfile)) setProfileDialogOpen(false);
                }}
              >
                {t("maven.add")}
              </Button>
            </>
          }
        >
          <Input
            autoFocus
            value={customProfile}
            placeholder={t("maven.profileId")}
            onChange={(event) => setCustomProfile(event.target.value)}
          />
        </Dialog>
      ) : null}
      {settingsDialogOpen ? (
        <MavenSettingsDialog
          initial={{ settingsPath, localRepositoryPath, mavenExecutablePath, javaHomePath }}
          error={configurationSaveError}
          onClose={() => setSettingsDialogOpen(false)}
          onSave={actions.updateLocalConfiguration}
        />
      ) : null}
    </section>
  );
}

function findMavenModule(
  modules: readonly MavenModule[],
  relativePath: string | null,
): MavenModule | null {
  if (!relativePath) return null;
  for (const module of modules) {
    if (module.relativePath === relativePath) return module;
    const nested = findMavenModule(module.modules, relativePath);
    if (nested) return nested;
  }
  return null;
}
