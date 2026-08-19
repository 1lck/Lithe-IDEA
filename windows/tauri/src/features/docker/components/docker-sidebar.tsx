import {
  ArrowClockwiseIcon as Refresh,
  ArrowFatLineDownIcon as Down,
  ArrowSquareOutIcon as OpenExternal,
  BugIcon as Bug,
  DownloadSimpleIcon as Download,
  DotsThreeIcon as More,
  FileIcon,
  FolderIcon,
  MagnifyingGlassIcon as Search,
  PauseIcon as Pause,
  PlayIcon as Play,
  ArrowsClockwiseIcon as Restart,
  StackIcon as ImageIcon,
  StopIcon as Stop,
  SlidersHorizontalIcon as Sliders,
  TerminalWindowIcon as Terminal,
  TrashIcon as Trash,
  UploadSimpleIcon as Upload,
  WarningCircleIcon as WarningCircle,
  XIcon as X,
} from "@/ui/icons";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import type { ComponentProps, ReactNode } from "react";
import { Alert, AlertAction, AlertDescription, AlertTitle } from "@/ui/alert";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import { ScrollArea } from "@/ui/scroll-area";
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyState,
  EmptyTitle,
} from "@/ui/empty";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import Dialog, { showPromptDialog } from "@/ui/dialog";
import Input from "@/ui/input";
import Textarea from "@/ui/textarea";
import {
  SidebarPanel,
  SidebarSearchPopover,
  SidebarSectionHeader,
  SidebarSectionLabel,
  SidebarTabBar,
  SidebarTitleBar,
} from "@/ui/sidebar";
import { SearchField } from "@/ui/search";
import { cn } from "@/utils/cn";
import {
  buildDockerImage,
  copyFromDockerContainer,
  copyToDockerContainer,
  deleteDockerEnvFile,
  getDockerComposeProject,
  getDockerInventory,
  getDockerProjectConfig,
  loginDockerRegistry,
  listDockerContainerFiles,
  openDockerEnvFile,
  openDockerDevContainer,
  pullDockerRegistryImage,
  pruneDockerResources,
  pushDockerRegistryImage,
  runDockerComposeAction,
  runDockerContainerAction,
  runDockerImage,
  runDockerImageAction,
  saveDockerProjectConfig,
  searchDockerRegistry,
  startDockerContainerLogStream,
  stopDockerContainerLogStream,
  tagDockerImage,
} from "../services/docker-api";
import type {
  DockerBuildPreset,
  DockerComposeAction,
  DockerComposePreset,
  DockerComposeProject,
  DockerComposeService,
  DockerContainer,
  DockerContainerAction,
  DockerDebugPreset,
  DockerDevContainer,
  DockerEnvFile,
  DockerContainerFileEntry,
  DockerImage,
  DockerPruneTarget,
  DockerInventory,
  DockerLogEvent,
  DockerLogExitEvent,
  DockerNetwork,
  DockerProjectConfig,
  DockerRegistrySearchResult,
  DockerRunPreset,
  DockerVolume,
} from "../types/docker.types";

type DockerSection =
  | "containers"
  | "compose"
  | "project"
  | "images"
  | "registry"
  | "volumes"
  | "networks"
  | "cleanup";
type DockerLogFilter = "all" | "stdout" | "stderr" | "errors";
type DockerLogLine = DockerLogEvent & { id: number };
type DockerDialogMode = "build" | "run" | null;
type DockerDetailTab = "logs" | "files";
type DockerTab = "resources" | "compose" | "project" | "registry";
type DockerContainerFilter = "all" | "running" | "stopped";

const maxLogLines = 1_000;
const dockerTabSections: Record<DockerTab, DockerSection[]> = {
  resources: ["containers", "images", "cleanup", "volumes", "networks"],
  compose: ["compose"],
  project: ["project"],
  registry: ["registry"],
};
const dockerTabs: Array<{ id: DockerTab; labelKey: string }> = [
  { id: "resources", labelKey: "docker.resources" },
  { id: "compose", labelKey: "docker.compose" },
  { id: "project", labelKey: "docker.project" },
  { id: "registry", labelKey: "docker.registry" },
];
const emptyComposeProject: DockerComposeProject = {
  workspacePath: null,
  files: [],
  services: [],
};
const emptyProjectConfig: DockerProjectConfig = {
  workspacePath: null,
  buildPresets: [],
  runPresets: [],
  composePresets: [],
  debugPresets: [],
  workspaceDebugPresets: [],
  envFiles: [],
  devContainers: [],
};

const emptyInventory: DockerInventory = {
  containers: [],
  images: [],
  volumes: [],
  networks: [],
};

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function isDockerConnectionError(message: string) {
  const normalizedMessage = message.toLowerCase();
  return [
    "cannot connect to the docker daemon",
    "docker cli was not found",
    "error during connect",
    "failed to connect",
    "is the docker daemon running",
    "permission denied while trying to connect to the docker api",
    "connection refused",
  ].some((fragment) => normalizedMessage.includes(fragment));
}

function getDockerUnavailableCopy(error: string, t: (key: string) => string) {
  if (error.toLowerCase().includes("docker cli was not found")) {
    return {
      title: t("docker.cliUnavailable"),
      description: t("docker.cliUnavailableDescription"),
    };
  }

  if (isDockerConnectionError(error)) {
    return {
      title: t("docker.notRunning"),
      description: t("docker.notRunningDescription"),
    };
  }

  return {
    title: t("docker.unavailable"),
    description: t("docker.unavailableDescription"),
  };
}

function openDockerConnectionDetailsBuffer(error: string, t: (key: string) => string) {
  const copy = getDockerUnavailableCopy(error, t);
  const content = `${copy.title}\n\n${copy.description}\n\n${t("docker.technicalDetails")}\n${error}\n`;
  const bufferStore = useBufferStore.getState();
  const bufferId = bufferStore.actions.openContent({
    type: "editor",
    path: "docker://connection-details",
    name: "Docker Connection.log",
    content,
    isVirtual: true,
    readOnly: true,
    language: "log",
  });
  const openedBuffer = useBufferStore.getState().buffers.find((buffer) => buffer.id === bufferId);
  if (openedBuffer?.type === "editor") {
    useBufferStore.getState().actions.updateBuffer({
      ...openedBuffer,
      content,
      savedContent: content,
      isDirty: false,
      isVirtual: true,
      readOnly: true,
      language: "log",
    });
  }
}

function DockerUnavailableState({
  error,
  title,
  description,
  isRetrying,
  onRetry,
}: {
  error: string;
  title?: string;
  description?: string;
  isRetrying: boolean;
  onRetry: () => void;
}) {
  const { t } = useTranslation();
  const fallbackCopy = getDockerUnavailableCopy(error, t);

  return (
    <Empty className="min-h-0 flex-none gap-3 px-4 py-5" role="status">
      <EmptyHeader className="gap-1.5">
        <EmptyMedia variant="icon" className="size-9 border border-border/70 bg-accent">
          <WarningCircle className="size-4.5 text-subtle-foreground" />
        </EmptyMedia>
        <EmptyTitle className="ui-text-base">{title ?? fallbackCopy.title}</EmptyTitle>
        <EmptyDescription className="max-w-[34ch]">
          {description ?? fallbackCopy.description}
        </EmptyDescription>
      </EmptyHeader>
      <EmptyContent className="flex-row justify-center gap-1.5">
        <Button type="button" variant="default" size="sm" disabled={isRetrying} onClick={onRetry}>
          {isRetrying ? <Spinner compact /> : <Refresh />}
          {t("docker.retry")}
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          onClick={() => openDockerConnectionDetailsBuffer(error, t)}
        >
          <OpenExternal />
          {t("docker.details")}
        </Button>
      </EmptyContent>
    </Empty>
  );
}

function DockerInlineError({
  title,
  error,
  onDismiss,
  className,
}: {
  title: string;
  error: string;
  onDismiss: () => void;
  className?: string;
}) {
  const { t } = useTranslation();
  return (
    <Alert tone="error" className={cn("min-w-0", className)}>
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription className="min-w-0 select-text whitespace-pre-wrap wrap-break-word wrap-anywhere">
        {error}
      </AlertDescription>
      <AlertAction>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          tooltip={t("docker.dismiss")}
          tooltipSide="left"
          aria-label={`Dismiss ${title.toLowerCase()}`}
          onClick={onDismiss}
        >
          <X />
        </Button>
      </AlertAction>
    </Alert>
  );
}

function DockerCapabilityNotice({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <Alert tone="warning" role="status" className={cn("mx-2 mb-2 w-auto", className)}>
      <WarningCircle />
      <AlertDescription>{children}</AlertDescription>
    </Alert>
  );
}

interface DockerMenuAction {
  label: string;
  icon?: ReactNode;
  disabled?: boolean;
  destructive?: boolean;
  separatorBefore?: boolean;
  onSelect: () => void;
}

function DockerActionMenu({ label, actions }: { label: string; actions: DockerMenuAction[] }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            tooltip={label}
            tooltipSide="left"
            aria-label={label}
          />
        }
      >
        <More />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        {actions.map((action) => (
          <Fragment key={action.label}>
            {action.separatorBefore ? <DropdownMenuSeparator /> : null}
            <DropdownMenuItem
              variant={action.destructive ? "destructive" : "default"}
              disabled={action.disabled}
              onClick={action.onSelect}
            >
              {action.icon}
              {action.label}
            </DropdownMenuItem>
          </Fragment>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function getContainerStateVariant(
  container: DockerContainer,
): ComponentProps<typeof Badge>["variant"] {
  if (container.health === "unhealthy") return "error";
  if (container.health === "healthy") return "success";
  if (container.state === "running") return "success";
  if (container.state === "exited") return "warning";
  if (container.state === "paused") return "accent";
  return "muted";
}

function includesQuery(values: Array<string | null | undefined>, query: string) {
  if (!query) return true;
  return values.some((value) => value?.toLowerCase().includes(query));
}

function DockerResourceRow({
  title,
  description,
  status,
  active = false,
  onClick,
  actions,
}: {
  title: ReactNode;
  description?: ReactNode;
  status?: ReactNode;
  active?: boolean;
  onClick?: () => void;
  actions?: ReactNode;
}) {
  const content = (
    <>
      <span className="flex min-w-0 items-center gap-1.5">
        <span className="min-w-0 flex-1 truncate font-medium text-foreground ui-text-sm">
          {title}
        </span>
        {status}
      </span>
      {description ? (
        <span className="mt-0.5 block truncate text-subtle-foreground ui-text-sm">
          {description}
        </span>
      ) : null}
    </>
  );

  return (
    <div
      className={cn(
        "group/docker-row flex min-h-12 w-full min-w-0 items-center rounded-lg transition-colors hover:bg-accent/70",
        active && "bg-accent/80",
      )}
    >
      {onClick ? (
        <button
          type="button"
          className="min-w-0 flex-1 px-2.5 py-2 text-left outline-none focus-visible:ring-2 focus-visible:ring-primary/20"
          onClick={onClick}
        >
          {content}
        </button>
      ) : (
        <div className="min-w-0 flex-1 px-2.5 py-2">{content}</div>
      )}
      {actions ? (
        <div className="mr-1 shrink-0 opacity-0 transition-opacity group-hover/docker-row:opacity-100 group-focus-within/docker-row:opacity-100">
          {actions}
        </div>
      ) : null}
    </div>
  );
}

function quoteShellArg(value: string) {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function dockerExecCommand(containerId: string) {
  const shellProbe =
    "if command -v bash >/dev/null 2>&1; then exec bash; " +
    "elif command -v sh >/dev/null 2>&1; then exec sh; " +
    'else echo "No interactive shell found in this container." >&2; exit 127; fi';
  return `docker exec -it ${quoteShellArg(containerId)} sh -lc ${quoteShellArg(shellProbe)}`;
}

function dockerDebugCommand(containerId: string, command: string, workdir?: string | null) {
  const debugCommand = workdir?.trim()
    ? `cd ${quoteShellArg(workdir.trim())} && ${command}`
    : command;
  return `docker exec -it ${quoteShellArg(containerId)} sh -lc ${quoteShellArg(debugCommand)}`;
}

function openDebuggerPane() {
  const state = useUIState.getState();
  state.setBottomPaneActiveTab("debugger");
  state.setIsBottomPaneVisible(true);
}

function isErrorLogLine(line: string) {
  return /\b(error|exception|fatal|panic|failed|unhealthy|crash)\b/i.test(line);
}

function getPublishedTcpUrl(ports: string) {
  const match = ports.match(
    /(?:^|[\s,])(?:0\.0\.0\.0|127\.0\.0\.1|localhost|\[::\]|::)?(?::)?(\d+)->\d+\/tcp/,
  );
  if (!match?.[1]) return null;
  return `http://localhost:${match[1]}`;
}

function splitConfigLines(value: string) {
  return value
    .split(/[\n,]/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function getImageReference(image: DockerImage) {
  if (image.repository === "<none>" || image.tag === "<none>") return image.id;
  return `${image.repository}:${image.tag}`;
}

function parentContainerPath(path: string) {
  const normalized = path.trim().replace(/\/+$/, "") || "/";
  if (normalized === "/") return "/";
  const parent = normalized.slice(0, normalized.lastIndexOf("/")) || "/";
  return parent.startsWith("/") ? parent : `/${parent}`;
}

function formatFileSize(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function fileName(path: string) {
  return path.split(/[\\/]/).pop() || path;
}

function getComposeServiceVariant(
  service: DockerComposeService,
): ComponentProps<typeof Badge>["variant"] {
  if (service.health === "unhealthy") return "error";
  if (service.health === "healthy") return "success";
  if (service.state === "running") return "success";
  if (service.state === "exited") return "warning";
  return "muted";
}

function ContainerActions({
  container,
  busy,
  onAction,
  onOpenTerminal,
  onDebug,
  quickUrl,
  onOpenUrl,
}: {
  container: DockerContainer;
  busy: boolean;
  onAction: (container: DockerContainer, action: DockerContainerAction) => void;
  onOpenTerminal: (container: DockerContainer) => void;
  onDebug: (container: DockerContainer) => void;
  quickUrl: string | null;
  onOpenUrl: (url: string) => void;
}) {
  const { t } = useTranslation();
  const isRunning = container.state === "running";
  const isPaused = container.state === "paused";

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            tooltip={t("docker.containerActions")}
            tooltipSide="left"
            aria-label={t("docker.actionsFor", { name: container.name })}
          />
        }
      >
        <More className="size-3.5" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem
          disabled={busy || isRunning || isPaused}
          onClick={() => onAction(container, "start")}
        >
          <Play />
          {t("docker.start")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={busy || !isRunning} onClick={() => onAction(container, "stop")}>
          <Stop />
          {t("docker.stop")}
        </DropdownMenuItem>
        <DropdownMenuItem
          disabled={busy || (!isRunning && !isPaused)}
          onClick={() => onAction(container, isPaused ? "unpause" : "pause")}
        >
          {isPaused ? <Play /> : <Pause />}
          {isPaused ? t("docker.unpause") : t("docker.pause")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={busy} onClick={() => onAction(container, "restart")}>
          <Restart />
          {t("docker.restart")}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem disabled={busy || !isRunning} onClick={() => onOpenTerminal(container)}>
          <Terminal />
          {t("docker.openShell")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={busy || !isRunning} onClick={() => onDebug(container)}>
          <Bug />
          {t("docker.debug")}
        </DropdownMenuItem>
        <DropdownMenuItem
          disabled={busy || !quickUrl}
          onClick={() => {
            if (quickUrl) onOpenUrl(quickUrl);
          }}
        >
          <OpenExternal />
          {t("docker.openServiceUrl")}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          variant="destructive"
          disabled={busy || isRunning}
          onClick={() => onAction(container, "remove")}
        >
          <Trash />
          {t("docker.remove")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function ContainerRow({
  container,
  busy,
  selected,
  onSelect,
  onAction,
  onOpenTerminal,
  onDebug,
  onOpenUrl,
}: {
  container: DockerContainer;
  busy: boolean;
  selected: boolean;
  onSelect: (container: DockerContainer) => void;
  onAction: (container: DockerContainer, action: DockerContainerAction) => void;
  onOpenTerminal: (container: DockerContainer) => void;
  onDebug: (container: DockerContainer) => void;
  onOpenUrl: (url: string) => void;
}) {
  const quickUrl = getPublishedTcpUrl(container.ports);

  return (
    <DockerResourceRow
      active={selected}
      title={container.name}
      status={
        <Badge variant={getContainerStateVariant(container)} size="compact" className="capitalize">
          {container.health ?? container.state}
        </Badge>
      }
      description={
        <>
          {container.image}
          {container.ports ? ` · ${container.ports}` : ""}
          {container.size ? ` · ${container.size}` : ""}
        </>
      }
      actions={
        <ContainerActions
          container={container}
          busy={busy}
          onAction={onAction}
          onOpenTerminal={onOpenTerminal}
          onDebug={onDebug}
          quickUrl={quickUrl}
          onOpenUrl={onOpenUrl}
        />
      }
      onClick={() => onSelect(container)}
    />
  );
}

function ComposeServiceActions({
  service,
  busy,
  onAction,
  quickUrl,
  onOpenUrl,
}: {
  service: DockerComposeService;
  busy: boolean;
  onAction: (service: DockerComposeService, action: DockerComposeAction) => void;
  quickUrl: string | null;
  onOpenUrl: (url: string) => void;
}) {
  const { t } = useTranslation();
  const isRunning = service.state === "running";

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            tooltip={t("docker.serviceActions")}
            tooltipSide="left"
            aria-label={t("docker.actionsFor", { name: service.name })}
          />
        }
      >
        <More className="size-3.5" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem disabled={busy} onClick={() => onAction(service, "up")}>
          <Play />
          {t("docker.start")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={busy || !isRunning} onClick={() => onAction(service, "stop")}>
          <Stop />
          {t("docker.stop")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={busy} onClick={() => onAction(service, "restart")}>
          <Restart />
          {t("docker.restart")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={busy} onClick={() => onAction(service, "rebuild")}>
          <ImageIcon />
          {t("docker.rebuild")}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          disabled={busy || !quickUrl}
          onClick={() => {
            if (quickUrl) onOpenUrl(quickUrl);
          }}
        >
          <OpenExternal />
          {t("docker.openServiceUrl")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function ComposeServiceRow({
  service,
  busy,
  onAction,
  onOpenUrl,
}: {
  service: DockerComposeService;
  busy: boolean;
  onAction: (service: DockerComposeService, action: DockerComposeAction) => void;
  onOpenUrl: (url: string) => void;
}) {
  const quickUrl = getPublishedTcpUrl(service.ports);

  return (
    <DockerResourceRow
      title={service.name}
      status={
        <Badge variant={getComposeServiceVariant(service)} size="compact" className="capitalize">
          {service.health ?? service.state}
        </Badge>
      }
      actions={
        <ComposeServiceActions
          service={service}
          busy={busy}
          onAction={onAction}
          quickUrl={quickUrl}
          onOpenUrl={onOpenUrl}
        />
      }
      description={
        <>
          {service.containerName ?? service.status}
          {service.ports ? ` · ${service.ports}` : ""}
        </>
      }
    />
  );
}

function ImageRow({
  image,
  busy,
  onRun,
  onRemove,
}: {
  image: DockerImage;
  busy: boolean;
  onRun: (image: DockerImage) => void;
  onRemove: (image: DockerImage) => void;
}) {
  const { t } = useTranslation();
  const label = getImageReference(image);
  return (
    <DockerResourceRow
      title={label}
      actions={
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                tooltip={t("docker.imageActions")}
                tooltipSide="left"
                aria-label={t("docker.actionsFor", { name: label })}
              />
            }
          >
            <More className="size-3.5" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem disabled={busy} onClick={() => onRun(image)}>
              <Play />
              {t("docker.run")}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem variant="destructive" disabled={busy} onClick={() => onRemove(image)}>
              <Trash />
              {t("docker.remove")}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      }
      description={
        <>
          {image.size}
          {image.createdSince ? ` · ${image.createdSince}` : ""}
        </>
      }
    />
  );
}

function VolumeRow({ volume }: { volume: DockerVolume }) {
  return (
    <DockerResourceRow
      title={volume.name}
      description={
        <>
          {volume.driver}
          {volume.mountpoint ? ` · ${volume.mountpoint}` : ""}
        </>
      }
    />
  );
}

function NetworkRow({ network }: { network: DockerNetwork }) {
  return (
    <DockerResourceRow
      title={network.name}
      description={
        <>
          {network.driver}
          {network.scope ? ` · ${network.scope}` : ""}
        </>
      }
    />
  );
}

export function DockerSidebar() {
  const { t } = useTranslation();
  const rootFolderPath = useProjectStore((state) => state.rootFolderPath);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const [inventory, setInventory] = useState<DockerInventory>(emptyInventory);
  const [composeProject, setComposeProject] = useState<DockerComposeProject>(emptyComposeProject);
  const [projectConfig, setProjectConfig] = useState<DockerProjectConfig>(emptyProjectConfig);
  const [query, setQuery] = useState("");
  const [activeTab, setActiveTab] = useState<DockerTab>("resources");
  const [containerFilter, setContainerFilter] = useState<DockerContainerFilter>("all");
  const [collapsedSections, setCollapsedSections] = useState<Set<DockerSection>>(() => new Set());
  const [selectedContainerId, setSelectedContainerId] = useState<string | null>(null);
  const [logLines, setLogLines] = useState<DockerLogLine[]>([]);
  const [logQuery, setLogQuery] = useState("");
  const [logFilter, setLogFilter] = useState<DockerLogFilter>("all");
  const [logStreamId, setLogStreamId] = useState<string | null>(null);
  const [logError, setLogError] = useState<string | null>(null);
  const [detailTab, setDetailTab] = useState<DockerDetailTab>("logs");
  const [containerPath, setContainerPath] = useState("/");
  const [containerFiles, setContainerFiles] = useState<DockerContainerFileEntry[]>([]);
  const [isFilesLoading, setIsFilesLoading] = useState(false);
  const [filesError, setFilesError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isComposeLoading, setIsComposeLoading] = useState(false);
  const [isProjectConfigLoading, setIsProjectConfigLoading] = useState(false);
  const [busyContainerId, setBusyContainerId] = useState<string | null>(null);
  const [busyComposeService, setBusyComposeService] = useState<string | null>(null);
  const [busyDevContainerPath, setBusyDevContainerPath] = useState<string | null>(null);
  const [busyImageId, setBusyImageId] = useState<string | null>(null);
  const [busyPruneTarget, setBusyPruneTarget] = useState<DockerPruneTarget | null>(null);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [composeError, setComposeError] = useState<string | null>(null);
  const [projectConfigError, setProjectConfigError] = useState<string | null>(null);
  const [composeOutput, setComposeOutput] = useState<string | null>(null);
  const [dockerOutput, setDockerOutput] = useState<string | null>(null);
  const [dialogMode, setDialogMode] = useState<DockerDialogMode>(null);
  const [registryQuery, setRegistryQuery] = useState("");
  const [registryResults, setRegistryResults] = useState<DockerRegistrySearchResult[]>([]);
  const [registryError, setRegistryError] = useState<string | null>(null);
  const [registryOutput, setRegistryOutput] = useState<string | null>(null);
  const [isRegistryBusy, setIsRegistryBusy] = useState(false);
  const [buildDraft, setBuildDraft] = useState({
    contextPath: "",
    dockerfilePath: "",
    tag: "",
    buildArgs: "",
  });
  const [runDraft, setRunDraft] = useState({
    image: "",
    name: "",
    ports: "",
    volumes: "",
    env: "",
    envFiles: "",
    command: "",
  });
  const [registryDraft, setRegistryDraft] = useState({
    registry: "",
    username: "",
    password: "",
    image: "",
    target: "",
  });
  const localizedDockerTabs = useMemo(
    () => dockerTabs.map((tab) => ({ id: tab.id, label: t(tab.labelKey) })),
    [t],
  );
  const loadInventory = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const nextInventory = await getDockerInventory();
      setConnectionError(null);
      setInventory(nextInventory);
      setSelectedContainerId((current) => {
        if (current && nextInventory.containers.some((container) => container.id === current)) {
          return current;
        }
        return nextInventory.containers[0]?.id ?? null;
      });
    } catch (loadError) {
      setConnectionError(getErrorMessage(loadError));
      setInventory(emptyInventory);
      setSelectedContainerId(null);
      setLogLines([]);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadInventory();
  }, [loadInventory]);

  const loadComposeProject = useCallback(async () => {
    setIsComposeLoading(true);
    setComposeError(null);
    try {
      const nextProject = await getDockerComposeProject(rootFolderPath);
      setComposeProject(nextProject);
    } catch (loadError) {
      setComposeError(loadError instanceof Error ? loadError.message : String(loadError));
      setComposeProject(emptyComposeProject);
    } finally {
      setIsComposeLoading(false);
    }
  }, [rootFolderPath]);

  useEffect(() => {
    void loadComposeProject();
  }, [loadComposeProject]);

  const loadProjectConfig = useCallback(async () => {
    setIsProjectConfigLoading(true);
    setProjectConfigError(null);
    try {
      const nextConfig = await getDockerProjectConfig(rootFolderPath);
      setProjectConfig(nextConfig);
    } catch (loadError) {
      setProjectConfigError(loadError instanceof Error ? loadError.message : String(loadError));
      setProjectConfig(emptyProjectConfig);
    } finally {
      setIsProjectConfigLoading(false);
    }
  }, [rootFolderPath]);

  useEffect(() => {
    void loadProjectConfig();
  }, [loadProjectConfig]);

  const refreshDocker = useCallback(() => {
    if (activeTab === "resources" || activeTab === "registry") {
      void loadInventory();
      return;
    }
    if (activeTab === "compose") {
      void loadComposeProject();
      void loadInventory();
      return;
    }
    void loadProjectConfig();
  }, [activeTab, loadComposeProject, loadInventory, loadProjectConfig]);

  const markDockerUnavailable = useCallback((message: string) => {
    setConnectionError(message);
    setError(null);
    setInventory(emptyInventory);
    setSelectedContainerId(null);
    setLogLines([]);
  }, []);

  const handleDockerFailure = useCallback(
    (failure: unknown) => {
      const message = getErrorMessage(failure);
      if (isDockerConnectionError(message)) {
        markDockerUnavailable(message);
        return;
      }
      setError(message);
    },
    [markDockerUnavailable],
  );

  const selectedContainer = useMemo(
    () => inventory.containers.find((container) => container.id === selectedContainerId) ?? null,
    [inventory.containers, selectedContainerId],
  );

  useEffect(() => {
    setContainerPath("/");
    setContainerFiles([]);
    setFilesError(null);
  }, [selectedContainer?.id]);

  const loadContainerFiles = useCallback(async () => {
    if (!selectedContainer) {
      setContainerFiles([]);
      return;
    }

    setIsFilesLoading(true);
    setFilesError(null);
    try {
      const entries = await listDockerContainerFiles(selectedContainer.id, containerPath);
      setContainerFiles(entries);
    } catch (loadError) {
      setFilesError(loadError instanceof Error ? loadError.message : String(loadError));
      setContainerFiles([]);
    } finally {
      setIsFilesLoading(false);
    }
  }, [containerPath, selectedContainer]);

  useEffect(() => {
    if (!selectedContainer || detailTab !== "files") return;
    void loadContainerFiles();
  }, [detailTab, loadContainerFiles, selectedContainer]);

  useEffect(() => {
    if (!selectedContainer) {
      setLogLines([]);
      setLogError(null);
      return;
    }

    let cancelled = false;
    let activeStreamId: string | null = null;
    let removeLogListener: (() => void) | null = null;
    let removeExitListener: (() => void) | null = null;
    let nextLogId = 0;

    setLogLines([]);
    setLogError(null);
    setLogStreamId(null);

    const startLogStream = async () => {
      try {
        removeLogListener = await listen<DockerLogEvent>("docker-container-log", (event) => {
          const matchesStream = activeStreamId
            ? event.payload.streamId === activeStreamId
            : event.payload.containerId === selectedContainer.id;

          if (cancelled || !matchesStream) return;

          setLogLines((current) =>
            current
              .concat({
                ...event.payload,
                id: nextLogId++,
              })
              .slice(-maxLogLines),
          );
        });
        removeExitListener = await listen<DockerLogExitEvent>(
          "docker-container-log-exit",
          (event) => {
            const matchesStream = activeStreamId
              ? event.payload.streamId === activeStreamId
              : event.payload.containerId === selectedContainer.id;

            if (cancelled || !matchesStream) return;

            setLogStreamId(null);
            if (event.payload.error) {
              setLogError(event.payload.error);
            } else if (event.payload.code && event.payload.code !== 0) {
              setLogError(`Docker log stream exited with code ${event.payload.code}.`);
            }
          },
        );

        const nextStreamId = await startDockerContainerLogStream(selectedContainer.id, 300);
        if (cancelled) {
          void stopDockerContainerLogStream(nextStreamId);
          return;
        }
        activeStreamId = nextStreamId;
        setLogStreamId(nextStreamId);
      } catch (logsError) {
        if (!cancelled) {
          setLogError(logsError instanceof Error ? logsError.message : String(logsError));
        }
      }
    };

    void startLogStream();

    return () => {
      cancelled = true;
      removeLogListener?.();
      removeExitListener?.();
      setLogStreamId(null);
      if (activeStreamId) {
        void stopDockerContainerLogStream(activeStreamId);
      }
    };
  }, [selectedContainer]);

  const normalizedQuery = query.trim().toLowerCase();
  const filteredContainers = inventory.containers.filter((container) => {
    if (containerFilter === "running" && container.state !== "running") return false;
    if (containerFilter === "stopped" && container.state === "running") return false;

    return includesQuery(
      [
        container.name,
        container.image,
        container.status,
        container.state,
        container.ports,
        container.size,
      ],
      normalizedQuery,
    );
  });
  const filteredImages = inventory.images.filter((image) =>
    includesQuery([image.repository, image.tag, image.id, image.size], normalizedQuery),
  );
  const filteredVolumes = inventory.volumes.filter((volume) =>
    includesQuery([volume.name, volume.driver, volume.mountpoint], normalizedQuery),
  );
  const filteredNetworks = inventory.networks.filter((network) =>
    includesQuery([network.name, network.driver, network.scope], normalizedQuery),
  );
  const filteredComposeServices = composeProject.services.filter((service) =>
    includesQuery(
      [service.name, service.state, service.status, service.health, service.ports],
      normalizedQuery,
    ),
  );
  const composeEnvFilePaths = projectConfig.envFiles.map((envFile) => envFile.path);
  const projectConfigItemCount =
    projectConfig.envFiles.length +
    projectConfig.devContainers.length +
    projectConfig.buildPresets.length +
    projectConfig.runPresets.length +
    projectConfig.composePresets.length +
    projectConfig.debugPresets.length +
    projectConfig.workspaceDebugPresets.length;
  const normalizedLogQuery = logQuery.trim().toLowerCase();
  const filteredLogLines = logLines.filter((entry) => {
    if (logFilter === "stdout" && entry.stream !== "stdout") return false;
    if (logFilter === "stderr" && entry.stream !== "stderr") return false;
    if (logFilter === "errors" && !isErrorLogLine(entry.line)) return false;
    if (!normalizedLogQuery) return true;
    return entry.line.toLowerCase().includes(normalizedLogQuery);
  });

  const handleContainerAction = async (
    container: DockerContainer,
    action: DockerContainerAction,
  ) => {
    setBusyContainerId(container.id);
    setError(null);
    try {
      await runDockerContainerAction(container.id, action, action === "remove");
      await loadInventory();
    } catch (actionError) {
      handleDockerFailure(actionError);
    } finally {
      setBusyContainerId(null);
    }
  };

  const handleComposeAction = async (
    service: DockerComposeService | null,
    action: DockerComposeAction,
    envFiles: string[] = [],
  ) => {
    if (!composeProject.workspacePath || composeProject.files.length === 0) return;

    const busyKey = service?.name ?? "__project__";
    setBusyComposeService(busyKey);
    setComposeError(null);
    setComposeOutput(null);
    try {
      const output = await runDockerComposeAction({
        workspacePath: composeProject.workspacePath,
        files: composeProject.files,
        service: service?.name,
        action,
        envFiles,
      });
      const envFileSuffix =
        envFiles.length > 0
          ? ` with ${envFiles.length} env file${envFiles.length === 1 ? "" : "s"}`
          : "";
      setComposeOutput(output.trim() || `Docker Compose ${action} completed${envFileSuffix}.`);
      await loadComposeProject();
      await loadInventory();
    } catch (actionError) {
      const message = getErrorMessage(actionError);
      if (isDockerConnectionError(message)) markDockerUnavailable(message);
      setComposeError(message);
    } finally {
      setBusyComposeService(null);
    }
  };

  const openBuildDialog = () => {
    const contextPath = rootFolderPath ?? "";
    setBuildDraft({
      contextPath,
      dockerfilePath: contextPath ? `${contextPath.replace(/[\\/]+$/, "")}/Dockerfile` : "",
      tag: "",
      buildArgs: "",
    });
    setDockerOutput(null);
    setDialogMode("build");
  };

  const openRunDialog = (image: DockerImage) => {
    setRunDraft({
      image: getImageReference(image),
      name: "",
      ports: "",
      volumes: "",
      env: "",
      envFiles: "",
      command: "",
    });
    setDockerOutput(null);
    setDialogMode("run");
  };

  const applyBuildPreset = (preset: DockerBuildPreset) => {
    setBuildDraft({
      contextPath: preset.contextPath,
      dockerfilePath: preset.dockerfilePath ?? "",
      tag: preset.tag ?? "",
      buildArgs: preset.buildArgs.join("\n"),
    });
    setDockerOutput(null);
    setDialogMode("build");
  };

  const applyRunPreset = (preset: DockerRunPreset) => {
    setRunDraft({
      image: preset.image,
      name: preset.containerName ?? "",
      ports: preset.ports.join("\n"),
      volumes: preset.volumes.join("\n"),
      env: preset.env.join("\n"),
      envFiles: preset.envFiles.join("\n"),
      command: preset.command ?? "",
    });
    setDockerOutput(null);
    setDialogMode("run");
  };

  const handleBuildImage = async () => {
    const contextPath = buildDraft.contextPath.trim();
    if (!contextPath) return;

    setBusyImageId("__build__");
    setError(null);
    setDockerOutput(null);
    try {
      const output = await buildDockerImage({
        contextPath,
        dockerfilePath: buildDraft.dockerfilePath.trim() || undefined,
        tag: buildDraft.tag.trim() || undefined,
        buildArgs: splitConfigLines(buildDraft.buildArgs),
      });
      setDockerOutput(output.trim() || t("docker.imageBuildCompleted"));
      setDialogMode(null);
      await loadInventory();
    } catch (buildError) {
      handleDockerFailure(buildError);
    } finally {
      setBusyImageId(null);
    }
  };

  const handleRunImage = async () => {
    const image = runDraft.image.trim();
    if (!image) return;

    setBusyImageId(image);
    setError(null);
    setDockerOutput(null);
    try {
      const output = await runDockerImage({
        image,
        name: runDraft.name.trim() || undefined,
        ports: splitConfigLines(runDraft.ports),
        volumes: splitConfigLines(runDraft.volumes),
        env: splitConfigLines(runDraft.env),
        envFiles: splitConfigLines(runDraft.envFiles),
        command: runDraft.command.trim() || undefined,
        detach: true,
      });
      setDockerOutput(output.trim() || t("docker.startedImage", { image }));
      setDialogMode(null);
      await loadInventory();
    } catch (runError) {
      handleDockerFailure(runError);
    } finally {
      setBusyImageId(null);
    }
  };

  const saveProjectConfig = async (nextConfig: DockerProjectConfig) => {
    if (!rootFolderPath) return;
    setProjectConfigError(null);
    const savedConfig = await saveDockerProjectConfig(rootFolderPath, nextConfig);
    setProjectConfig(savedConfig);
  };

  const handleSaveBuildPreset = async () => {
    if (!rootFolderPath || !buildDraft.contextPath.trim()) return;
    const name = await showPromptDialog(t("docker.buildPresetName"), {
      title: t("docker.saveBuildPreset"),
      placeholder: "production image",
      confirmLabel: t("ui.save"),
    });
    const presetName = name?.trim();
    if (!presetName) return;

    try {
      await saveProjectConfig({
        ...projectConfig,
        buildPresets: projectConfig.buildPresets
          .filter((preset) => preset.name !== presetName)
          .concat({
            name: presetName,
            contextPath: buildDraft.contextPath.trim(),
            dockerfilePath: buildDraft.dockerfilePath.trim() || null,
            tag: buildDraft.tag.trim() || null,
            buildArgs: splitConfigLines(buildDraft.buildArgs),
          }),
      });
    } catch (saveError) {
      setProjectConfigError(saveError instanceof Error ? saveError.message : String(saveError));
    }
  };

  const handleSaveRunPreset = async () => {
    if (!rootFolderPath || !runDraft.image.trim()) return;
    const name = await showPromptDialog(t("docker.runPresetName"), {
      title: t("docker.saveRunPreset"),
      placeholder: "web app",
      confirmLabel: t("ui.save"),
    });
    const presetName = name?.trim();
    if (!presetName) return;

    try {
      await saveProjectConfig({
        ...projectConfig,
        runPresets: projectConfig.runPresets
          .filter((preset) => preset.name !== presetName)
          .concat({
            name: presetName,
            image: runDraft.image.trim(),
            containerName: runDraft.name.trim() || null,
            ports: splitConfigLines(runDraft.ports),
            volumes: splitConfigLines(runDraft.volumes),
            env: splitConfigLines(runDraft.env),
            envFiles: splitConfigLines(runDraft.envFiles),
            command: runDraft.command.trim() || null,
          }),
      });
    } catch (saveError) {
      setProjectConfigError(saveError instanceof Error ? saveError.message : String(saveError));
    }
  };

  const handleSaveComposePreset = async () => {
    if (!rootFolderPath || composeProject.files.length === 0) return;
    const name = await showPromptDialog(t("docker.composePresetName"), {
      title: t("docker.saveComposePreset"),
      placeholder: "start workspace",
      confirmLabel: t("ui.save"),
    });
    const presetName = name?.trim();
    if (!presetName) return;

    try {
      await saveProjectConfig({
        ...projectConfig,
        composePresets: projectConfig.composePresets
          .filter((preset) => preset.name !== presetName)
          .concat({
            name: presetName,
            files: composeProject.files,
            service: null,
            action: "up",
            envFiles: projectConfig.envFiles.map((envFile) => envFile.path),
          }),
      });
    } catch (saveError) {
      setProjectConfigError(saveError instanceof Error ? saveError.message : String(saveError));
    }
  };

  const handleRunComposePreset = async (preset: DockerComposePreset) => {
    if (!composeProject.workspacePath) return;

    const busyKey = `preset:${preset.name}`;
    setBusyComposeService(busyKey);
    setComposeError(null);
    setComposeOutput(null);
    try {
      const output = await runDockerComposeAction({
        workspacePath: composeProject.workspacePath,
        files: preset.files.length > 0 ? preset.files : composeProject.files,
        service: preset.service ?? undefined,
        action: preset.action,
        envFiles: preset.envFiles,
      });
      setComposeOutput(
        output.trim() || t("docker.composePresetCompleted", { name: preset.name }),
      );
      await loadComposeProject();
      await loadInventory();
    } catch (actionError) {
      const message = getErrorMessage(actionError);
      if (isDockerConnectionError(message)) markDockerUnavailable(message);
      setComposeError(message);
    } finally {
      setBusyComposeService(null);
    }
  };

  const openEnvFile = async (envFile: DockerEnvFile) => {
    setProjectConfigError(null);
    try {
      await handleFileSelect(envFile.path, false);
    } catch (readError) {
      setProjectConfigError(readError instanceof Error ? readError.message : String(readError));
    }
  };

  const handleOpenEnvFile = async () => {
    if (!rootFolderPath) return;

    const path = await showPromptDialog(t("docker.envFilePath"), {
      title: t("docker.openEnvFile"),
      placeholder: ".env",
      confirmLabel: t("docker.open"),
      defaultValue: ".env",
    });
    const envPath = path?.trim();
    if (!envPath) return;

    setProjectConfigError(null);
    try {
      const { file } = await openDockerEnvFile(rootFolderPath, envPath);
      await loadProjectConfig();
      await handleFileSelect(file.path, false);
    } catch (openError) {
      setProjectConfigError(openError instanceof Error ? openError.message : String(openError));
    }
  };

  const handleDeleteEnvFile = async (envFile: DockerEnvFile) => {
    if (!rootFolderPath) return;

    const confirmation = await showPromptDialog(
      t("docker.typeDeleteToRemove", { path: envFile.relativePath }),
      {
        title: t("docker.deleteEnvFile"),
      placeholder: "delete",
        confirmLabel: t("docker.delete"),
      },
    );
    if (confirmation?.trim().toLowerCase() !== "delete") return;

    setProjectConfigError(null);
    try {
      await deleteDockerEnvFile(rootFolderPath, envFile.path);
      await loadProjectConfig();
    } catch (deleteError) {
      setProjectConfigError(
        deleteError instanceof Error ? deleteError.message : String(deleteError),
      );
    }
  };

  const handleOpenDevContainer = async (devContainer: DockerDevContainer) => {
    if (!rootFolderPath || devContainer.kind === "unsupported") return;

    setBusyDevContainerPath(devContainer.configPath);
    setProjectConfigError(null);
    setDockerOutput(null);
    try {
      const result = await openDockerDevContainer(rootFolderPath, devContainer.configPath);
      window.dispatchEvent(
        new CustomEvent("create-terminal-with-command", {
          detail: {
            command: result.command,
            name: result.name,
          },
        }),
      );
      setDockerOutput(result.output.trim() || t("docker.opened", { name: devContainer.name }));
      await loadInventory();
      await loadComposeProject();
    } catch (openError) {
      const message = getErrorMessage(openError);
      if (isDockerConnectionError(message)) markDockerUnavailable(message);
      setProjectConfigError(message);
    } finally {
      setBusyDevContainerPath(null);
    }
  };

  const handleImageRemove = async (image: DockerImage) => {
    setBusyImageId(image.id);
    setError(null);
    setDockerOutput(null);
    try {
      const output = await runDockerImageAction(image.id, "remove", false);
      setDockerOutput(output.trim() || t("docker.removed", { name: getImageReference(image) }));
      await loadInventory();
    } catch (removeError) {
      handleDockerFailure(removeError);
    } finally {
      setBusyImageId(null);
    }
  };

  const handlePrune = async (target: DockerPruneTarget, includeVolumes = false) => {
    const label = includeVolumes
      ? t("docker.pruneTargetWithVolumes", { target })
      : target;
    const confirmation = await showPromptDialog(t("docker.typePruneToClean", { target: label }), {
      title: t("docker.confirmDockerCleanup"),
      placeholder: "prune",
      confirmLabel: t("docker.prune"),
    });
    if (confirmation?.trim().toLowerCase() !== "prune") return;

    setBusyPruneTarget(target);
    setError(null);
    setDockerOutput(null);
    try {
      const output = await pruneDockerResources(target, includeVolumes);
      setDockerOutput(output.trim() || t("docker.cleanupCompleted", { target }));
      await loadInventory();
      await loadComposeProject();
    } catch (pruneError) {
      handleDockerFailure(pruneError);
    } finally {
      setBusyPruneTarget(null);
    }
  };

  const openContainerTerminal = (container: DockerContainer) => {
    window.dispatchEvent(
      new CustomEvent("create-terminal-with-command", {
        detail: {
          command: dockerExecCommand(container.id),
          name: `Docker: ${container.name}`,
        },
      }),
    );
  };

  const startDockerDebugSession = ({
    containerId,
    containerName,
    command,
    workdir,
    configId,
  }: {
    containerId: string;
    containerName: string;
    command: string;
    workdir?: string | null;
    configId: string;
  }) => {
    const debugCommand = dockerDebugCommand(containerId, command, workdir);
    window.dispatchEvent(
      new CustomEvent("create-terminal-with-command", {
        detail: {
          command: debugCommand,
          name: `Debug: ${containerName}`,
        },
      }),
    );
    useDebuggerStore.getState().actions.startSession({
      id: `docker_debug_${Date.now()}`,
      name: `Debug: ${containerName}`,
      configId,
      command: debugCommand,
      startedAt: Date.now(),
      status: "running",
    });
    openDebuggerPane();
  };

  const handleDebugContainer = async (container: DockerContainer) => {
    const command = await showPromptDialog(t("docker.debugCommand"), {
      title: t("docker.debugInContainer"),
      placeholder: "python -m pdb app.py",
      confirmLabel: t("docker.debug"),
    });
    if (!command?.trim()) return;

    const workdir = await showPromptDialog(t("docker.workingDirectory"), {
      title: t("docker.debugInContainer"),
      placeholder: "/workspace",
      confirmLabel: t("docker.start"),
    });

    startDockerDebugSession({
      containerId: container.id,
      containerName: container.name,
      command: command.trim(),
      workdir: workdir?.trim() || null,
      configId: `docker-container-${container.id}`,
    });
  };

  const handleSaveDebugPreset = async () => {
    if (!rootFolderPath) return;
    const name = await showPromptDialog(t("docker.debugPresetName"), {
      title: t("docker.saveDebugPreset"),
      placeholder: "debug server",
      confirmLabel: t("ui.next"),
    });
    const presetName = name?.trim();
    if (!presetName) return;

    const command = await showPromptDialog(t("docker.debugCommand"), {
      title: t("docker.saveDebugPreset"),
      placeholder: "python -m pdb app.py",
      confirmLabel: t("ui.next"),
    });
    if (!command?.trim()) return;

    const workdir = await showPromptDialog(t("docker.workingDirectory"), {
      title: t("docker.saveDebugPreset"),
      placeholder: "/workspace",
      confirmLabel: t("ui.save"),
    });

    try {
      await saveProjectConfig({
        ...projectConfig,
        debugPresets: projectConfig.debugPresets
          .filter((preset) => preset.name !== presetName)
          .concat({
            name: presetName,
            command: command.trim(),
            workdir: workdir?.trim() || null,
            target: "container",
            source: "project",
          }),
      });
    } catch (saveError) {
      setProjectConfigError(saveError instanceof Error ? saveError.message : String(saveError));
    }
  };

  const handleRunDebugPreset = (preset: DockerDebugPreset) => {
    if (!selectedContainer) {
      setProjectConfigError(t("docker.selectRunningContainerBeforeDebugPreset"));
      return;
    }
    if (selectedContainer.state !== "running") {
      setProjectConfigError(t("docker.debugPresetRequiresRunningContainer"));
      return;
    }

    setProjectConfigError(null);
    startDockerDebugSession({
      containerId: selectedContainer.id,
      containerName: selectedContainer.name,
      command: preset.command,
      workdir: preset.workdir,
      configId: `docker-debug-preset-${preset.name}`,
    });
  };

  const handleDeletePreset = async (
    kind: "build" | "run" | "compose" | "debug",
    presetName: string,
  ) => {
    if (!rootFolderPath) return;

    try {
      await saveProjectConfig({
        ...projectConfig,
        buildPresets:
          kind === "build"
            ? projectConfig.buildPresets.filter((preset) => preset.name !== presetName)
            : projectConfig.buildPresets,
        runPresets:
          kind === "run"
            ? projectConfig.runPresets.filter((preset) => preset.name !== presetName)
            : projectConfig.runPresets,
        composePresets:
          kind === "compose"
            ? projectConfig.composePresets.filter((preset) => preset.name !== presetName)
            : projectConfig.composePresets,
        debugPresets:
          kind === "debug"
            ? projectConfig.debugPresets.filter((preset) => preset.name !== presetName)
            : projectConfig.debugPresets,
      });
    } catch (deleteError) {
      setProjectConfigError(
        deleteError instanceof Error ? deleteError.message : String(deleteError),
      );
    }
  };

  const openServiceUrl = (url: string) => {
    void openUrl(url);
  };

  const handleCopyFromContainer = async (entry: DockerContainerFileEntry) => {
    if (!selectedContainer) return;
    const hostPath = await showPromptDialog(t("docker.copyToHostPath"), {
      title: t("docker.copyFromContainer"),
      placeholder: "/host/path",
      confirmLabel: t("docker.copy"),
    });
    if (!hostPath?.trim()) return;

    setFilesError(null);
    setDockerOutput(null);
    try {
      const output = await copyFromDockerContainer({
        containerId: selectedContainer.id,
        containerPath: entry.path,
        hostPath: hostPath.trim(),
      });
      setDockerOutput(
        output.trim() || t("docker.copiedToHost", { source: entry.path, target: hostPath.trim() }),
      );
    } catch (copyError) {
      setFilesError(copyError instanceof Error ? copyError.message : String(copyError));
    }
  };

  const handleCopyToContainer = async () => {
    if (!selectedContainer) return;
    const hostPath = await showPromptDialog(t("docker.hostFileOrFolderPath"), {
      title: t("docker.copyToContainer"),
      placeholder: "/host/path",
      confirmLabel: t("ui.next"),
    });
    if (!hostPath?.trim()) return;

    const containerDestination = await showPromptDialog(t("docker.containerDestinationPath"), {
      title: t("docker.copyToContainer"),
      defaultValue: containerPath,
      placeholder: "/container/path",
      confirmLabel: t("docker.copy"),
    });
    if (!containerDestination?.trim()) return;

    setFilesError(null);
    setDockerOutput(null);
    try {
      const output = await copyToDockerContainer({
        containerId: selectedContainer.id,
        hostPath: hostPath.trim(),
        containerPath: containerDestination.trim(),
      });
      setDockerOutput(
        output.trim() ||
          t("docker.copiedToContainer", {
            source: hostPath.trim(),
            target: containerDestination.trim(),
          }),
      );
      await loadContainerFiles();
    } catch (copyError) {
      setFilesError(copyError instanceof Error ? copyError.message : String(copyError));
    }
  };

  const handleRegistryFailure = (failure: unknown) => {
    const message = getErrorMessage(failure);
    if (isDockerConnectionError(message)) markDockerUnavailable(message);
    setRegistryError(message);
  };

  const handleRegistrySearch = async () => {
    const query = registryQuery.trim();
    if (!query) return;

    setIsRegistryBusy(true);
    setRegistryError(null);
    try {
      const results = await searchDockerRegistry(query, 25);
      setRegistryResults(results);
    } catch (searchError) {
      handleRegistryFailure(searchError);
      setRegistryResults([]);
    } finally {
      setIsRegistryBusy(false);
    }
  };

  const handleRegistryLogin = async () => {
    if (!registryDraft.username.trim() || !registryDraft.password) return;

    setIsRegistryBusy(true);
    setRegistryError(null);
    setRegistryOutput(null);
    try {
      const output = await loginDockerRegistry({
        registry: registryDraft.registry.trim() || undefined,
        username: registryDraft.username.trim(),
        password: registryDraft.password,
      });
      setRegistryOutput(output.trim() || t("docker.registryLoginCompleted"));
      setRegistryDraft((current) => ({ ...current, password: "" }));
    } catch (loginError) {
      handleRegistryFailure(loginError);
    } finally {
      setIsRegistryBusy(false);
    }
  };

  const handleRegistryPull = async (image: string) => {
    const imageName = image.trim();
    if (!imageName) return;

    setIsRegistryBusy(true);
    setRegistryError(null);
    setRegistryOutput(null);
    try {
      const output = await pullDockerRegistryImage(imageName);
      setRegistryOutput(output.trim() || t("docker.pulledImage", { image: imageName }));
      await loadInventory();
    } catch (pullError) {
      handleRegistryFailure(pullError);
    } finally {
      setIsRegistryBusy(false);
    }
  };

  const handleRegistryPush = async () => {
    const imageName = registryDraft.image.trim();
    if (!imageName) return;

    setIsRegistryBusy(true);
    setRegistryError(null);
    setRegistryOutput(null);
    try {
      const output = await pushDockerRegistryImage(imageName);
      setRegistryOutput(output.trim() || t("docker.pushedImage", { image: imageName }));
    } catch (pushError) {
      handleRegistryFailure(pushError);
    } finally {
      setIsRegistryBusy(false);
    }
  };

  const handleTagImage = async () => {
    const source = registryDraft.image.trim();
    const target = registryDraft.target.trim();
    if (!source || !target) return;

    setIsRegistryBusy(true);
    setRegistryError(null);
    setRegistryOutput(null);
    try {
      const output = await tagDockerImage(source, target);
      setRegistryOutput(output.trim() || t("docker.taggedImage", { source, target }));
      await loadInventory();
    } catch (tagError) {
      handleRegistryFailure(tagError);
    } finally {
      setIsRegistryBusy(false);
    }
  };

  const isDockerDaemonReady = !isLoading && connectionError === null;
  const isActiveTabLoading =
    activeTab === "resources" || activeTab === "registry"
      ? isLoading
      : activeTab === "compose"
        ? isComposeLoading
        : isProjectConfigLoading;

  const renderSection = (section: DockerSection, rows: ReactNode, filteredCount?: number) => {
    const title = t(`docker.section.${section}`);
    const isVisible = dockerTabSections[activeTab].includes(section);
    const isCollapsed = collapsedSections.has(section);
    const hasSectionHeader = activeTab === "resources";

    return (
      <section
        key={section}
        className={cn("min-w-0", hasSectionHeader && "pt-2 first:pt-0", !isVisible && "hidden")}
      >
        {hasSectionHeader ? (
          <SidebarSectionHeader
            variant="surface"
            expanded={!isCollapsed}
            count={filteredCount}
            onToggle={() =>
              setCollapsedSections((current) => {
                const next = new Set(current);
                if (next.has(section)) {
                  next.delete(section);
                } else {
                  next.add(section);
                }
                return next;
              })
            }
          >
            {title}
          </SidebarSectionHeader>
        ) : null}
        {!hasSectionHeader || !isCollapsed ? <div className="space-y-0.5">{rows}</div> : null}
      </section>
    );
  };

  return (
    <>
      <SidebarPanel className="font-sans select-none">
        <SidebarTitleBar title="Docker">
          <SidebarSearchPopover
            value={query}
            onChange={setQuery}
            placeholder={t("docker.searchDocker")}
            aria-label={t("docker.searchDockerResources")}
          />
          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-xs"
                  active={containerFilter !== "all"}
                  tooltip={t("docker.viewOptions")}
                  tooltipSide="bottom"
                  aria-label={t("docker.viewOptions")}
                />
              }
            >
              <Sliders />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuRadioGroup
                value={containerFilter}
                onValueChange={(value) => setContainerFilter(value as DockerContainerFilter)}
              >
                <DropdownMenuLabel>{t("docker.containers")}</DropdownMenuLabel>
                <DropdownMenuRadioItem value="all" closeOnClick>
                  {t("docker.all")}
                </DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="running" closeOnClick>
                  {t("docker.running")}
                </DropdownMenuRadioItem>
                <DropdownMenuRadioItem value="stopped" closeOnClick>
                  {t("docker.stopped")}
                </DropdownMenuRadioItem>
              </DropdownMenuRadioGroup>
              <DropdownMenuSeparator />
              <DropdownMenuItem disabled={isActiveTabLoading} onClick={refreshDocker}>
                {isActiveTabLoading ? <Spinner compact /> : <Refresh />}
                {t("docker.refresh")}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </SidebarTitleBar>

        <SidebarTabBar items={localizedDockerTabs} value={activeTab} onChange={setActiveTab} />

        {activeTab === "resources" && error && !connectionError ? (
          <DockerInlineError
            title={t("docker.actionFailed")}
            error={error}
            onDismiss={() => setError(null)}
            className="rounded-none border-x-0"
          />
        ) : null}

        {activeTab === "resources" && connectionError ? (
          <DockerUnavailableState
            error={connectionError}
            isRetrying={isLoading}
            onRetry={() => void loadInventory()}
          />
        ) : activeTab === "resources" && isLoading ? (
          <div className="flex flex-1 items-center justify-center">
            <Spinner label={t("docker.loadingResources")} showLabel compact />
          </div>
        ) : activeTab === "compose" && composeError ? (
          <DockerUnavailableState
            error={composeError}
            title={
              isDockerConnectionError(composeError) ? undefined : t("docker.composeUnavailable")
            }
            description={
              isDockerConnectionError(composeError)
                ? undefined
                : t("docker.composeUnavailableDescription")
            }
            isRetrying={isComposeLoading}
            onRetry={() => void loadComposeProject()}
          />
        ) : activeTab === "compose" && isComposeLoading ? (
          <div className="flex flex-1 items-center justify-center">
            <Spinner label={t("docker.loadingCompose")} showLabel compact />
          </div>
        ) : (
          <>
            <ScrollArea className="min-h-0 flex-1" contentClassName="space-y-2 px-2 py-2">
              {renderSection(
                "containers",
                filteredContainers.length > 0 ? (
                  filteredContainers.map((container) => (
                    <ContainerRow
                      key={container.id}
                      container={container}
                      busy={busyContainerId === container.id}
                      selected={selectedContainerId === container.id}
                      onSelect={(nextContainer) => setSelectedContainerId(nextContainer.id)}
                      onAction={handleContainerAction}
                      onOpenTerminal={openContainerTerminal}
                      onDebug={(nextContainer) => void handleDebugContainer(nextContainer)}
                      onOpenUrl={openServiceUrl}
                    />
                  ))
                ) : (
                  <EmptyState message={t("docker.noMatchingContainers")} />
                ),
                filteredContainers.length,
              )}
              {renderSection(
                "compose",
                composeError ? (
                  <Empty tone="error" role="alert">
                    <EmptyDescription>{composeError}</EmptyDescription>
                  </Empty>
                ) : !rootFolderPath ? (
                  <EmptyState message={t("docker.openWorkspaceInspectCompose")} />
                ) : composeProject.files.length === 0 ? (
                  <EmptyState message={t("docker.noComposeFiles")} />
                ) : (
                  <>
                    <DockerResourceRow
                      title={t("docker.composeProject")}
                      description={composeProject.files.map(fileName).join(", ")}
                      status={
                        <Badge variant="muted" size="compact">
                          {t("docker.servicesCount", { count: composeProject.services.length })}
                        </Badge>
                      }
                      actions={
                        <DockerActionMenu
                          label={t("docker.composeProjectActions")}
                          actions={[
                            {
                              label: t("docker.startWithEnvFiles"),
                              icon: <FileIcon />,
                              disabled:
                                busyComposeService !== null || composeEnvFilePaths.length === 0,
                              onSelect: () =>
                                void handleComposeAction(null, "up", composeEnvFilePaths),
                            },
                            {
                              label: t("docker.savePreset"),
                              disabled: busyComposeService !== null,
                              onSelect: () => void handleSaveComposePreset(),
                            },
                            {
                              label: t("docker.stopProject"),
                              icon: <Down />,
                              disabled: busyComposeService !== null,
                              separatorBefore: true,
                              onSelect: () => void handleComposeAction(null, "down"),
                            },
                          ]}
                        />
                      }
                    />
                    {composeOutput ? (
                      <div className="ui-text-sm mx-2 mb-1 max-h-16 overflow-auto whitespace-pre-wrap rounded border border-border/60 bg-background px-2 py-1 font-mono text-subtle-foreground">
                        {composeOutput}
                      </div>
                    ) : null}
                    {filteredComposeServices.length > 0 ? (
                      filteredComposeServices.map((service) => (
                        <ComposeServiceRow
                          key={service.name}
                          service={service}
                          busy={busyComposeService === service.name}
                          onAction={(nextService, action) =>
                            void handleComposeAction(nextService, action)
                          }
                          onOpenUrl={openServiceUrl}
                        />
                      ))
                    ) : (
                      <Empty>
                        <EmptyDescription>
                          {composeProject.services.length > 0
                            ? t("docker.noMatchingComposeServices")
                            : t("docker.noComposeServicesFound")}
                        </EmptyDescription>
                      </Empty>
                    )}
                  </>
                ),
                filteredComposeServices.length,
              )}
              {renderSection(
                "project",
                !rootFolderPath ? (
                  <EmptyState message={t("docker.openWorkspaceManagePresets")} />
                ) : isProjectConfigLoading ? (
                  <div
                    className="flex items-center justify-center py-8"
                    role="status"
                    aria-live="polite"
                  >
                    <Spinner label={t("docker.loadingProjectConfig")} showLabel compact />
                  </div>
                ) : (
                  <>
                    {projectConfigError ? (
                      <DockerInlineError
                        title={t("docker.projectActionFailed")}
                        error={projectConfigError}
                        onDismiss={() => setProjectConfigError(null)}
                        className="mx-2 mb-1 w-auto"
                      />
                    ) : null}
                    {connectionError ? (
                      <DockerCapabilityNotice>
                        {t("docker.offlineProjectFilesAvailable")}
                      </DockerCapabilityNotice>
                    ) : null}
                    {projectConfigItemCount === 0 ? (
                      <div className="space-y-1 px-2 py-1">
                        <EmptyState message={t("docker.noEnvFilesOrPresets")} />
                        <div className="flex flex-wrap items-center gap-1">
                          <Button
                            type="button"
                            variant="ghost"
                            size="xs"
                            className="h-6 px-1.5 ui-text-sm"
                            onClick={() => void handleOpenEnvFile()}
                          >
                            <FileIcon className="size-3.5" />
                            Env
                          </Button>
                          <Button
                            type="button"
                            variant="ghost"
                            size="xs"
                            className="h-6 px-1.5 ui-text-sm"
                            onClick={() => void handleSaveDebugPreset()}
                          >
                            <Bug className="size-3.5" />
                            {t("docker.saveDebug")}
                          </Button>
                        </div>
                      </div>
                    ) : (
                      <>
                        <SidebarSectionLabel
                          trailing={
                            <DockerActionMenu
                              label={t("docker.projectActions")}
                              actions={[
                                {
                                  label: t("docker.openEnvFile"),
                                  icon: <FileIcon />,
                                  onSelect: () => void handleOpenEnvFile(),
                                },
                                {
                                  label: t("docker.saveDebugPreset"),
                                  icon: <Bug />,
                                  onSelect: () => void handleSaveDebugPreset(),
                                },
                              ]}
                            />
                          }
                        >
                          {t("docker.workspace")}
                        </SidebarSectionLabel>
                        {projectConfig.devContainers.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.devContainers")}</SidebarSectionLabel>
                            {projectConfig.devContainers.map((devContainer) => (
                              <DockerResourceRow
                                key={devContainer.configPath}
                                title={devContainer.name}
                                description={
                                  <>
                                    {devContainer.kind}
                                    {devContainer.service ? ` · ${devContainer.service}` : ""}
                                    {devContainer.image ? ` · ${devContainer.image}` : ""}
                                    {` · ${devContainer.relativePath}`}
                                  </>
                                }
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: devContainer.name })}
                                    actions={[
                                      {
                                        label:
                                          busyDevContainerPath === devContainer.configPath
                                            ? t("docker.opening")
                                            : t("docker.open"),
                                        icon:
                                          busyDevContainerPath === devContainer.configPath ? (
                                            <Spinner compact />
                                          ) : (
                                            <OpenExternal />
                                          ),
                                        disabled:
                                          !isDockerDaemonReady ||
                                          busyDevContainerPath !== null ||
                                          devContainer.kind === "unsupported",
                                        onSelect: () => void handleOpenDevContainer(devContainer),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                        {projectConfig.workspaceDebugPresets.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.launchConfigs")}</SidebarSectionLabel>
                            {projectConfig.workspaceDebugPresets.map((preset) => (
                              <DockerResourceRow
                                key={`${preset.source}-${preset.name}`}
                                title={preset.name}
                                description={
                                  <>
                                    {preset.command}
                                    {preset.workdir ? ` · ${preset.workdir}` : ""}
                                  </>
                                }
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: preset.name })}
                                    actions={[
                                      {
                                        label: t("docker.run"),
                                        icon: <Play />,
                                        disabled: !isDockerDaemonReady,
                                        onSelect: () => handleRunDebugPreset(preset),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                        {projectConfig.debugPresets.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.debugPresets")}</SidebarSectionLabel>
                            {projectConfig.debugPresets.map((preset) => (
                              <DockerResourceRow
                                key={preset.name}
                                title={preset.name}
                                description={
                                  <>
                                    {preset.command}
                                    {preset.workdir ? ` · ${preset.workdir}` : ""}
                                  </>
                                }
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: preset.name })}
                                    actions={[
                                      {
                                        label: t("docker.run"),
                                        icon: <Play />,
                                        disabled: !isDockerDaemonReady,
                                        onSelect: () => handleRunDebugPreset(preset),
                                      },
                                      {
                                        label: t("docker.delete"),
                                        icon: <Trash />,
                                        destructive: true,
                                        separatorBefore: true,
                                        onSelect: () =>
                                          void handleDeletePreset("debug", preset.name),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                        {projectConfig.envFiles.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.envFiles")}</SidebarSectionLabel>
                            {projectConfig.envFiles.map((envFile) => (
                              <DockerResourceRow
                                key={envFile.path}
                                title={
                                  <>
                                    <FileIcon className="size-3.5 shrink-0 text-subtle-foreground" />
                                    {envFile.relativePath}
                                  </>
                                }
                                description={`${envFile.variableCount} ${
                                  envFile.variableCount === 1
                                    ? t("docker.variable")
                                    : t("docker.variables")
                                }`}
                                onClick={() => void openEnvFile(envFile)}
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: envFile.relativePath })}
                                    actions={[
                                      {
                                        label: t("docker.open"),
                                        icon: <FileIcon />,
                                        onSelect: () => void openEnvFile(envFile),
                                      },
                                      {
                                        label: t("docker.delete"),
                                        icon: <Trash />,
                                        destructive: true,
                                        separatorBefore: true,
                                        onSelect: () => void handleDeleteEnvFile(envFile),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                        {projectConfig.buildPresets.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.buildPresets")}</SidebarSectionLabel>
                            {projectConfig.buildPresets.map((preset) => (
                              <DockerResourceRow
                                key={preset.name}
                                title={preset.name}
                                description={preset.tag || preset.contextPath}
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: preset.name })}
                                    actions={[
                                      {
                                        label: t("docker.usePreset"),
                                        icon: <ImageIcon />,
                                        onSelect: () => applyBuildPreset(preset),
                                      },
                                      {
                                        label: t("docker.delete"),
                                        icon: <Trash />,
                                        destructive: true,
                                        separatorBefore: true,
                                        onSelect: () =>
                                          void handleDeletePreset("build", preset.name),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                        {projectConfig.runPresets.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.runPresets")}</SidebarSectionLabel>
                            {projectConfig.runPresets.map((preset) => (
                              <DockerResourceRow
                                key={preset.name}
                                title={preset.name}
                                description={
                                  <>
                                    {preset.image}
                                    {preset.envFiles.length > 0 ? ` · ${t("docker.envFile")}` : ""}
                                  </>
                                }
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: preset.name })}
                                    actions={[
                                      {
                                        label: t("docker.usePreset"),
                                        icon: <Play />,
                                        onSelect: () => applyRunPreset(preset),
                                      },
                                      {
                                        label: t("docker.delete"),
                                        icon: <Trash />,
                                        destructive: true,
                                        separatorBefore: true,
                                        onSelect: () => void handleDeletePreset("run", preset.name),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                        {projectConfig.composePresets.length > 0 ? (
                          <div className="space-y-0.5">
                            <SidebarSectionLabel>{t("docker.composePresets")}</SidebarSectionLabel>
                            {projectConfig.composePresets.map((preset) => (
                              <DockerResourceRow
                                key={preset.name}
                                title={preset.name}
                                description={
                                  <>
                                    {preset.action}
                                    {preset.service ? ` · ${preset.service}` : ""}
                                  </>
                                }
                                actions={
                                  <DockerActionMenu
                                    label={t("docker.actionsFor", { name: preset.name })}
                                    actions={[
                                      {
                                        label:
                                          busyComposeService === `preset:${preset.name}`
                                            ? t("docker.runningEllipsis")
                                            : t("docker.run"),
                                        icon:
                                          busyComposeService === `preset:${preset.name}` ? (
                                            <Spinner compact />
                                          ) : (
                                            <Play />
                                          ),
                                        disabled:
                                          !isDockerDaemonReady || busyComposeService !== null,
                                        onSelect: () => void handleRunComposePreset(preset),
                                      },
                                      {
                                        label: t("docker.delete"),
                                        icon: <Trash />,
                                        destructive: true,
                                        separatorBefore: true,
                                        onSelect: () =>
                                          void handleDeletePreset("compose", preset.name),
                                      },
                                    ]}
                                  />
                                }
                              />
                            ))}
                          </div>
                        ) : null}
                      </>
                    )}
                  </>
                ),
                projectConfigItemCount,
              )}
              {renderSection(
                "images",
                <>
                  <div className="flex items-center justify-between gap-2 px-2 py-1">
                    <div className="min-w-0 truncate ui-text-sm text-subtle-foreground">
                      {t("docker.buildAndRunLocalImages")}
                    </div>
                    <Button
                      type="button"
                      variant="ghost"
                      size="xs"
                      className="h-6 px-1.5 ui-text-sm"
                      disabled={busyImageId !== null}
                      onClick={openBuildDialog}
                    >
                      <ImageIcon className="size-3.5" />
                      {t("docker.build")}
                    </Button>
                  </div>
                  {dockerOutput ? (
                    <div className="ui-text-sm mx-2 mb-1 max-h-16 overflow-auto whitespace-pre-wrap rounded border border-border/60 bg-background px-2 py-1 font-mono text-subtle-foreground">
                      {dockerOutput}
                    </div>
                  ) : null}
                  {filteredImages.length > 0 ? (
                    filteredImages.map((image) => (
                      <ImageRow
                        key={`${image.id}-${image.tag}`}
                        image={image}
                        busy={busyImageId === image.id || busyImageId === getImageReference(image)}
                        onRun={openRunDialog}
                        onRemove={(nextImage) => void handleImageRemove(nextImage)}
                      />
                    ))
                  ) : (
                    <EmptyState message={t("docker.noMatchingImages")} />
                  )}
                </>,
                filteredImages.length,
              )}
              {renderSection(
                "registry",
                <>
                  {connectionError ? (
                    <DockerCapabilityNotice>
                      {t("docker.registryOfflineNotice")}
                    </DockerCapabilityNotice>
                  ) : null}
                  <div className="space-y-3 px-2 py-2">
                    <div className="space-y-1">
                      <SidebarSectionLabel className="h-5 px-0">
                        {t("docker.dockerHub")}
                      </SidebarSectionLabel>
                      <div className="flex min-w-0 items-center gap-1.5">
                        <SearchField
                          value={registryQuery}
                          onChange={setRegistryQuery}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") void handleRegistrySearch();
                          }}
                          placeholder={t("docker.searchImages")}
                          aria-label={t("docker.searchDockerHub")}
                          size="xs"
                          className="min-w-0 flex-1 rounded-lg"
                        />
                        <Button
                          type="button"
                          variant="default"
                          size="xs"
                          disabled={isRegistryBusy || !registryQuery.trim()}
                          onClick={() => void handleRegistrySearch()}
                        >
                          {isRegistryBusy ? <Spinner compact /> : <Search />}
                          {t("workbench.search")}
                        </Button>
                      </div>
                    </div>
                    <div className="space-y-1">
                      <SidebarSectionLabel className="h-5 px-0">
                        {t("docker.imageActions")}
                      </SidebarSectionLabel>
                      <Input
                        value={registryDraft.image}
                        onChange={(event) =>
                          setRegistryDraft((current) => ({
                            ...current,
                            image: event.target.value,
                          }))
                        }
                        placeholder={t("docker.imageExamplePlaceholder")}
                        size="xs"
                        className="w-full rounded-lg"
                      />
                      <Input
                        value={registryDraft.target}
                        onChange={(event) =>
                          setRegistryDraft((current) => ({
                            ...current,
                            target: event.target.value,
                          }))
                        }
                        placeholder={t("docker.targetTag")}
                        size="xs"
                        className="w-full rounded-lg"
                      />
                      <div className="flex flex-wrap items-center gap-1">
                        <Button
                          type="button"
                          variant="ghost"
                          size="xs"
                          disabled={
                            isRegistryBusy || !isDockerDaemonReady || !registryDraft.image.trim()
                          }
                          onClick={() => void handleRegistryPull(registryDraft.image)}
                        >
                          {t("docker.pull")}
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="xs"
                          disabled={
                            isRegistryBusy || !isDockerDaemonReady || !registryDraft.image.trim()
                          }
                          onClick={() => void handleRegistryPush()}
                        >
                          {t("docker.push")}
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="xs"
                          disabled={
                            isRegistryBusy ||
                            !isDockerDaemonReady ||
                            !registryDraft.image.trim() ||
                            !registryDraft.target.trim()
                          }
                          onClick={() => void handleTagImage()}
                        >
                          {t("docker.tag")}
                        </Button>
                      </div>
                    </div>
                    <div className="space-y-1">
                      <SidebarSectionLabel className="h-5 px-0">
                        {t("docker.registryLogin")}
                      </SidebarSectionLabel>
                      <Input
                        value={registryDraft.registry}
                        onChange={(event) =>
                          setRegistryDraft((current) => ({
                            ...current,
                            registry: event.target.value,
                          }))
                        }
                        placeholder={t("docker.registryOptional")}
                        size="xs"
                        className="w-full rounded-lg"
                      />
                      <Input
                        value={registryDraft.username}
                        onChange={(event) =>
                          setRegistryDraft((current) => ({
                            ...current,
                            username: event.target.value,
                          }))
                        }
                        placeholder={t("docker.username")}
                        size="xs"
                        className="w-full rounded-lg"
                      />
                      <Input
                        value={registryDraft.password}
                        onChange={(event) =>
                          setRegistryDraft((current) => ({
                            ...current,
                            password: event.target.value,
                          }))
                        }
                        type="password"
                        placeholder={t("docker.password")}
                        size="xs"
                        className="w-full rounded-lg"
                      />
                      <Button
                        type="button"
                        variant="ghost"
                        size="xs"
                        disabled={
                          isRegistryBusy ||
                          !registryDraft.username.trim() ||
                          !registryDraft.password
                        }
                        onClick={() => void handleRegistryLogin()}
                      >
                        {t("docker.login")}
                      </Button>
                    </div>
                  </div>
                  {registryError ? (
                    <DockerInlineError
                      title={t("docker.registryActionFailed")}
                      error={registryError}
                      onDismiss={() => setRegistryError(null)}
                      className="mx-2 mb-1 w-auto"
                    />
                  ) : null}
                  {registryOutput ? (
                    <div className="ui-text-sm mx-2 mb-1 max-h-16 overflow-auto whitespace-pre-wrap rounded border border-border/60 bg-background px-2 py-1 font-mono text-subtle-foreground">
                      {registryOutput}
                    </div>
                  ) : null}
                  {registryResults.length > 0 ? (
                    registryResults.map((result) => (
                      <DockerResourceRow
                        key={result.name}
                        title={result.name}
                        description={
                          <>
                            {result.starCount
                              ? t("docker.starsCount", { count: result.starCount })
                              : t("docker.registryImage")}
                            {result.official === "[OK]" ? ` · ${t("docker.official")}` : ""}
                            {result.automated === "[OK]" ? ` · ${t("docker.automated")}` : ""}
                            {result.description ? ` · ${result.description}` : ""}
                          </>
                        }
                        actions={
                          <DockerActionMenu
                            label={t("docker.actionsFor", { name: result.name })}
                            actions={[
                              {
                                label: t("docker.pull"),
                                icon: <Download />,
                                disabled: isRegistryBusy || !isDockerDaemonReady,
                                onSelect: () => void handleRegistryPull(result.name),
                              },
                            ]}
                          />
                        }
                      />
                    ))
                  ) : (
                    <EmptyState message={t("docker.searchDockerHubToFindImages")} />
                  )}
                </>,
                registryResults.length,
              )}
              {renderSection(
                "cleanup",
                <div className="grid grid-cols-2 gap-1 px-2 py-1">
                  {(
                    [
                      ["containers", t("docker.containers")],
                      ["images", t("docker.images")],
                      ["volumes", t("docker.volumes")],
                      ["networks", t("docker.networks")],
                      ["system", t("docker.system")],
                    ] as Array<[DockerPruneTarget, string]>
                  ).map(([target, label]) => (
                    <Button
                      key={target}
                      type="button"
                      variant="ghost"
                      size="xs"
                      className="h-7 justify-start px-2 ui-text-sm"
                      disabled={busyPruneTarget !== null}
                      onClick={() => void handlePrune(target, target === "system")}
                    >
                      {busyPruneTarget === target ? (
                        <Spinner compact />
                      ) : (
                        <Trash className="size-3.5" />
                      )}
                      {t("docker.pruneTarget", { target: label })}
                    </Button>
                  ))}
                </div>,
                5,
              )}
              {renderSection(
                "volumes",
                filteredVolumes.length > 0 ? (
                  filteredVolumes.map((volume) => <VolumeRow key={volume.name} volume={volume} />)
                ) : (
                  <EmptyState message={t("docker.noMatchingVolumes")} />
                ),
                filteredVolumes.length,
              )}
              {renderSection(
                "networks",
                filteredNetworks.length > 0 ? (
                  filteredNetworks.map((network) => (
                    <NetworkRow key={network.id} network={network} />
                  ))
                ) : (
                  <EmptyState message={t("docker.noMatchingNetworks")} />
                ),
                filteredNetworks.length,
              )}
            </ScrollArea>

            {activeTab === "resources" && selectedContainer ? (
              <div className="max-h-72 shrink-0 border-t border-border/70 bg-surface/35">
                <div className="flex h-8 items-center justify-between gap-2 px-2">
                  <div className="min-w-0">
                    <div className="truncate ui-text-sm font-medium text-foreground">
                      {selectedContainer.name}
                    </div>
                    <div className="ui-text-sm text-subtle-foreground">
                      {detailTab === "logs"
                        ? logStreamId
                          ? t("docker.streamingLogs")
                          : t("docker.logsStopped")
                        : containerPath}
                    </div>
                  </div>
                  <div className="flex items-center gap-1">
                    {(["logs", "files"] as DockerDetailTab[]).map((tab) => (
                      <Button
                        key={tab}
                        type="button"
                        variant={detailTab === tab ? "accent" : "ghost"}
                        size="xs"
                        className="h-6 px-1.5 ui-text-sm"
                        onClick={() => setDetailTab(tab)}
                      >
                        {tab === "logs" ? t("docker.logs") : t("docker.files")}
                      </Button>
                    ))}
                    {detailTab === "logs" ? (
                      <Button
                        type="button"
                        variant="ghost"
                        size="xs"
                        className="h-6 px-1.5 ui-text-sm"
                        disabled={logLines.length === 0}
                        onClick={() => setLogLines([])}
                      >
                        {t("ui.clear")}
                      </Button>
                    ) : (
                      <Button
                        type="button"
                        variant="ghost"
                        size="xs"
                        className="h-6 px-1.5 ui-text-sm"
                        onClick={() => void handleCopyToContainer()}
                      >
                        <Upload className="size-3.5" />
                        {t("docker.copyIn")}
                      </Button>
                    )}
                  </div>
                </div>
                {detailTab === "logs" ? (
                  <>
                    <div className="flex items-center gap-1 border-t border-border/50 px-2 py-1">
                      <div className="flex min-w-0 flex-1 items-center gap-1 rounded border border-border/70 bg-background px-1.5">
                        <Search className="size-3.5 shrink-0 text-subtle-foreground" />
                        <input
                          value={logQuery}
                          onChange={(event) => setLogQuery(event.target.value)}
                          placeholder={t("docker.searchLogs")}
                          className="h-6 min-w-0 flex-1 bg-transparent ui-text-sm text-foreground outline-none placeholder:text-subtle-foreground"
                        />
                      </div>
                      {(["all", "stderr", "errors"] as DockerLogFilter[]).map((filter) => (
                        <Button
                          key={filter}
                          type="button"
                          variant={logFilter === filter ? "accent" : "ghost"}
                          size="xs"
                          className="h-6 px-1.5 ui-text-sm"
                          onClick={() => setLogFilter(filter)}
                        >
                          {filter === "all"
                            ? t("docker.logFilterAll")
                            : filter === "stderr"
                              ? t("docker.logFilterErr")
                              : t("docker.logFilterErrors")}
                        </Button>
                      ))}
                    </div>
                    {logError ? (
                      <div className="border-t border-border/50 px-2 py-1 ui-text-sm text-destructive">
                        {logError}
                      </div>
                    ) : null}
                    <div className="ui-text-sm max-h-36 overflow-auto border-t border-border/50 px-2 py-1 font-mono leading-4">
                      {filteredLogLines.length > 0 ? (
                        filteredLogLines.map((entry) => (
                          <div
                            key={entry.id}
                            className={cn(
                              "whitespace-pre-wrap wrap-break-word",
                              entry.stream === "stderr"
                                ? "text-destructive"
                                : "text-subtle-foreground",
                            )}
                          >
                            {entry.line}
                          </div>
                        ))
                      ) : (
                        <div className="text-subtle-foreground">
                          {logLines.length > 0
                            ? t("docker.noMatchingLogLines")
                            : t("docker.waitingForLogs")}
                        </div>
                      )}
                    </div>
                  </>
                ) : (
                  <>
                    <div className="flex items-center gap-1 border-t border-border/50 px-2 py-1">
                      <Button
                        type="button"
                        variant="ghost"
                        size="xs"
                        className="h-6 px-1.5 ui-text-sm"
                        disabled={containerPath === "/"}
                        onClick={() => setContainerPath(parentContainerPath(containerPath))}
                      >
                        {t("docker.up")}
                      </Button>
                      <div className="ui-text-sm min-w-0 flex-1 truncate rounded border border-border/70 bg-background px-2 py-1 font-mono text-subtle-foreground">
                        {containerPath}
                      </div>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-xs"
                          className="ui-text-sm"
                        tooltip={t("docker.refreshFiles")}
                        aria-label={t("docker.refreshFiles")}
                        disabled={isFilesLoading}
                        onClick={() => void loadContainerFiles()}
                      >
                        {isFilesLoading ? <Spinner compact /> : <Refresh className="size-3.5" />}
                      </Button>
                    </div>
                    {filesError ? (
                      <div className="border-t border-border/50 px-2 py-1 ui-text-sm text-destructive">
                        {filesError}
                      </div>
                    ) : null}
                    <div className="max-h-44 overflow-auto border-t border-border/50 py-1">
                      {isFilesLoading ? (
                        <div className="px-2 py-2 ui-text-sm text-subtle-foreground">
                          {t("docker.loadingFiles")}
                        </div>
                      ) : containerFiles.length > 0 ? (
                        containerFiles.map((entry) => (
                          <div
                            key={entry.path}
                            role="button"
                            tabIndex={entry.isDirectory ? 0 : -1}
                            className="flex w-full items-center gap-2 px-2 py-1 text-left hover:bg-accent"
                            onClick={() => {
                              if (entry.isDirectory) setContainerPath(entry.path);
                            }}
                            onKeyDown={(event) => {
                              if (!entry.isDirectory) return;
                              if (event.key === "Enter" || event.key === " ") {
                                event.preventDefault();
                                setContainerPath(entry.path);
                              }
                            }}
                          >
                            {entry.isDirectory ? (
                              <FolderIcon
                                className="size-4 shrink-0 text-subtle-foreground"
                                weight="duotone"
                              />
                            ) : (
                              <FileIcon
                                className="size-4 shrink-0 text-subtle-foreground"
                                weight="duotone"
                              />
                            )}
                            <div className="min-w-0 flex-1">
                              <div className="truncate ui-text-sm text-foreground">
                                {entry.name}
                              </div>
                              <div className="truncate ui-text-sm text-subtle-foreground">
                                {entry.isDirectory ? t("docker.directory") : formatFileSize(entry.size)}
                                {entry.mode ? ` · ${entry.mode}` : ""}
                              </div>
                            </div>
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon-xs"
                              className="ui-text-sm"
                              tooltip={t("docker.copyToHost")}
                              tooltipSide="left"
                              aria-label={t("docker.copyFileToHost", { name: entry.name })}
                              onClick={(event) => {
                                event.stopPropagation();
                                void handleCopyFromContainer(entry);
                              }}
                            >
                              <Download className="size-3.5" weight="fill" />
                            </Button>
                          </div>
                        ))
                      ) : (
                        <EmptyState message={t("docker.noFilesFound")} />
                      )}
                    </div>
                  </>
                )}
              </div>
            ) : null}
          </>
        )}
      </SidebarPanel>

      {dialogMode ? (
        <Dialog
          title={dialogMode === "build" ? t("docker.buildDockerImage") : t("docker.runDockerImage")}
          icon={dialogMode === "build" ? ImageIcon : Play}
          onClose={() => setDialogMode(null)}
          size="md"
          footer={
            <>
              <Button variant="ghost" onClick={() => setDialogMode(null)}>
                {t("ui.cancel")}
              </Button>
              {dialogMode === "build" ? (
                <>
                  <Button
                    variant="ghost"
                    onClick={() => void handleSaveBuildPreset()}
                    disabled={!rootFolderPath || !buildDraft.contextPath.trim()}
                  >
                    {t("docker.savePreset")}
                  </Button>
                  <Button
                    onClick={handleBuildImage}
                    disabled={!isDockerDaemonReady || !buildDraft.contextPath.trim()}
                  >
                    {t("docker.build")}
                  </Button>
                </>
              ) : (
                <>
                  <Button
                    variant="ghost"
                    onClick={() => void handleSaveRunPreset()}
                    disabled={!rootFolderPath || !runDraft.image.trim()}
                  >
                    {t("docker.savePreset")}
                  </Button>
                  <Button
                    onClick={handleRunImage}
                    disabled={!isDockerDaemonReady || !runDraft.image.trim()}
                  >
                    {t("docker.run")}
                  </Button>
                </>
              )}
            </>
          }
        >
          {(dialogMode === "build" || dialogMode === "run") && connectionError ? (
            <DockerCapabilityNotice className="mx-0 mb-3">
              {dialogMode === "build"
                ? t("docker.startDockerBeforeBuilding")
                : t("docker.startDockerBeforeRunning")}
            </DockerCapabilityNotice>
          ) : null}
          {dialogMode === "build" ? (
            <div className="space-y-3">
              <div className="space-y-1.5">
                <label htmlFor="docker-build-context" className="ui-text-sm block text-foreground">
                  {t("docker.contextPath")}
                </label>
                <Input
                  id="docker-build-context"
                  value={buildDraft.contextPath}
                  onChange={(event) =>
                    setBuildDraft((current) => ({
                      ...current,
                      contextPath: event.target.value,
                    }))
                  }
                  placeholder="/path/to/project"
                />
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-build-file" className="ui-text-sm block text-foreground">
                  Dockerfile
                </label>
                <Input
                  id="docker-build-file"
                  value={buildDraft.dockerfilePath}
                  onChange={(event) =>
                    setBuildDraft((current) => ({
                      ...current,
                      dockerfilePath: event.target.value,
                    }))
                  }
                  placeholder="/path/to/Dockerfile"
                />
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-build-tag" className="ui-text-sm block text-foreground">
                  {t("docker.tag")}
                </label>
                <Input
                  id="docker-build-tag"
                  value={buildDraft.tag}
                  onChange={(event) =>
                    setBuildDraft((current) => ({ ...current, tag: event.target.value }))
                  }
                  placeholder="my-app:latest"
                />
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-build-args" className="ui-text-sm block text-foreground">
                  {t("docker.buildArgs")}
                </label>
                <Textarea
                  id="docker-build-args"
                  value={buildDraft.buildArgs}
                  onChange={(event) =>
                    setBuildDraft((current) => ({
                      ...current,
                      buildArgs: event.target.value,
                    }))
                  }
                  placeholder="NODE_ENV=production"
                  className="min-h-20 font-mono"
                />
              </div>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="space-y-1.5">
                <label htmlFor="docker-run-image" className="ui-text-sm block text-foreground">
                  {t("docker.image")}
                </label>
                <Input
                  id="docker-run-image"
                  value={runDraft.image}
                  onChange={(event) =>
                    setRunDraft((current) => ({ ...current, image: event.target.value }))
                  }
                  placeholder="nginx:latest"
                />
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-run-name" className="ui-text-sm block text-foreground">
                  {t("docker.containerName")}
                </label>
                <Input
                  id="docker-run-name"
                  value={runDraft.name}
                  onChange={(event) =>
                    setRunDraft((current) => ({ ...current, name: event.target.value }))
                  }
                  placeholder="my-container"
                />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <label htmlFor="docker-run-ports" className="ui-text-sm block text-foreground">
                    {t("docker.ports")}
                  </label>
                  <Textarea
                    id="docker-run-ports"
                    value={runDraft.ports}
                    onChange={(event) =>
                      setRunDraft((current) => ({ ...current, ports: event.target.value }))
                    }
                    placeholder="8080:80"
                    className="min-h-20 font-mono"
                  />
                </div>
                <div className="space-y-1.5">
                  <label htmlFor="docker-run-volumes" className="ui-text-sm block text-foreground">
                    {t("docker.volumes")}
                  </label>
                  <Textarea
                    id="docker-run-volumes"
                    value={runDraft.volumes}
                    onChange={(event) =>
                      setRunDraft((current) => ({ ...current, volumes: event.target.value }))
                    }
                    placeholder="/host:/container"
                    className="min-h-20 font-mono"
                  />
                </div>
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-run-env" className="ui-text-sm block text-foreground">
                  {t("docker.environment")}
                </label>
                <Textarea
                  id="docker-run-env"
                  value={runDraft.env}
                  onChange={(event) =>
                    setRunDraft((current) => ({ ...current, env: event.target.value }))
                  }
                  placeholder="KEY=value"
                  className="min-h-20 font-mono"
                />
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-run-env-files" className="ui-text-sm block text-foreground">
                  {t("docker.envFiles")}
                </label>
                <Textarea
                  id="docker-run-env-files"
                  value={runDraft.envFiles}
                  onChange={(event) =>
                    setRunDraft((current) => ({ ...current, envFiles: event.target.value }))
                  }
                  placeholder=".env"
                  className="min-h-16 font-mono"
                />
              </div>
              <div className="space-y-1.5">
                <label htmlFor="docker-run-command" className="ui-text-sm block text-foreground">
                  {t("docker.command")}
                </label>
                <Input
                  id="docker-run-command"
                  value={runDraft.command}
                  onChange={(event) =>
                    setRunDraft((current) => ({ ...current, command: event.target.value }))
                  }
                  placeholder="npm start"
                />
              </div>
            </div>
          )}
        </Dialog>
      ) : null}
    </>
  );
}
