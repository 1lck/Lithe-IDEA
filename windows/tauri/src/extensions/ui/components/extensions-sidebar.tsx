import {
  ArrowClockwiseIcon as RefreshCw,
  ArrowCounterClockwiseIcon as Reset,
  BrainIcon as Brain,
  CheckIcon as Check,
  DatabaseIcon as Database,
  DownloadSimpleIcon as Download,
  PackageIcon as Package,
  PaintBrushIcon as PaintBrush,
  PlugsConnectedIcon as PlugsConnected,
  PlusIcon as Plus,
  RobotIcon as Robot,
  MagnifyingGlassIcon as Search,
  SparkleIcon as Sparkles,
  TextTIcon as TextT,
  TrashIcon as Trash,
  WarningCircleIcon as WarningCircle,
  XCircleIcon as XCircle,
} from "@/ui/icons";
import { invoke } from "@/platform/tauri-core";
import { getVisibleIconThemes } from "@/extensions/icon-themes/icon-theme-normalization";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent,
  type ReactNode,
} from "react";
import { useShallow } from "zustand/react/shallow";
import { iconThemeRegistry } from "@/extensions/icon-themes/icon-theme-registry";
import { useExtensionStore } from "@/extensions/registry/extension-store";
import type { ExtensionRuntimeIssue } from "@/extensions/registry/extension-store-types";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { DynamicIcon } from "@/extensions/ui/components/dynamic-icon";
import {
  getManifestAIProviderContributions,
  getManifestDatabaseContributions,
  getManifestIconContributions,
  getManifestIntegrationContributions,
  getManifestThemeContributions,
} from "@/extensions/types/extension-contributions";
import { SkillsCommand } from "@/features/ai/components/skills/skills-command";
import {
  createSkillFromMarketplace,
  hasMarketplaceSkillUpdate,
  hasSkillLocalOverride,
  isMarketplaceSkillInstalled,
  loadMarketplaceSkills,
  resetSkillLocalOverride,
  updateSkillFromMarketplace,
} from "@/features/ai/lib/skill-library";
import type { AgentConfig } from "@/features/ai/types/acp.types";
import type { AIChatSkill, MarketplaceSkill } from "@/features/ai/types/skills.types";
import { useToast } from "@/features/layout/contexts/toast-context";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Alert, AlertDescription } from "@/ui/alert";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { Dropdown, useDropdownMenu, type MenuItem } from "@/ui/dropdown";
import { EmptyState } from "@/ui/empty";
import { Spinner } from "@/ui/spinner";
import { SearchField } from "@/ui/search";
import { ScrollArea } from "@/ui/scroll-area";
import { cn } from "@/utils/cn";
import { PLATFORM_ARCH } from "@/utils/platform";

interface UnifiedExtension {
  id: string;
  name: string;
  description: string;
  category:
    | "language"
    | "theme"
    | "icon-theme"
    | "database"
    | "ai"
    | "integration"
    | "skill"
    | "agent";
  isInstalled: boolean;
  isEnabled: boolean;
  version?: string;
  extensions?: string[];
  publisher?: string;
  isMarketplace?: boolean;
  isBundled?: boolean;
  runtimeIssues?: ExtensionRuntimeIssue[];
  skill?: AIChatSkill;
  marketplaceSkill?: MarketplaceSkill;
  agentId?: string;
  icon?: string | null;
  canInstall?: boolean;
  packageSize?: number;
  contributionSummary?: string[];
  selectionId?: string;
  appearanceOptions?: AppearanceOption[];
  isActive?: boolean;
}

type Translator = (key: string, values?: Record<string, string | number>) => string;

interface AppearanceOption {
  id: string;
  name: string;
  description?: string;
}

const FILTER_TABS = [
  { id: "all", labelKey: "extensions.all" },
  { id: "language", labelKey: "extensions.languages", icon: TextT },
  { id: "theme", labelKey: "extensions.themes", icon: PaintBrush },
  { id: "icon-theme", labelKey: "extensions.iconThemes", icon: Package },
  { id: "database", labelKey: "extensions.databases", icon: Database },
  { id: "ai", labelKey: "extensions.ai", icon: Sparkles },
  { id: "integration", labelKey: "extensions.integrations", icon: PlugsConnected },
  { id: "skill", labelKey: "extensions.skills", icon: Brain },
  { id: "agent", labelKey: "extensions.agents", icon: Robot },
] as const;

type ExtensionTabId = (typeof FILTER_TABS)[number]["id"];
const FILTER_TAB_IDS = new Set<string>(FILTER_TABS.map((tab) => tab.id));
const LOCAL_FILE_ICON_MODULES = import.meta.glob(
  "../../../extensions/bundled/icon-themes/lithe/icons/files/*.svg",
  { eager: true, import: "default", query: "?url" },
) as Record<string, string>;
const LOCAL_FILE_ICON_URLS = new Map(
  Object.entries(LOCAL_FILE_ICON_MODULES).map(([path, url]) => [
    path
      .split("/")
      .pop()
      ?.replace(/\.svg$/i, "") ?? path,
    url,
  ]),
);

const SIMPLE_ICON_SLUGS: Record<string, string> = {
  alibaba: "alibabacloud",
  alibabacloud: "alibabacloud",
  anthropic: "anthropic",
  claude: "claude",
  "claude-acp": "claude",
  "claude-code": "claude",
  duckdb: "duckdb",
  gemini: "googlegemini",
  "gemini-cli": "googlegemini",
  "google-gemini": "googlegemini",
  googlegemini: "googlegemini",
  mongodb: "mongodb",
  mongo: "mongodb",
  mysql: "mysql",
  opencode: "opencode",
  postgres: "postgresql",
  postgresql: "postgresql",
  qwen: "qwen",
  "qwen-code": "qwen",
  redis: "redis",
  sentry: "sentry",
  gitlab: "gitlab",
  sqlite: "sqlite",
  v0: "v0",
  vercel: "vercel",
};

const LOCAL_ICON_ALIASES: Record<string, string> = {
  "c++": "cpp",
  "c#": "csharp",
  csharp: "csharp",
  duckdb: "database",
  icon: "package",
  "icon-theme": "package",
  javascriptreact: "react",
  js: "javascript",
  kimi: "agents",
  "kimi-cli": "agents",
  less: "css",
  md: "markdown",
  mongodb: "mongo",
  mysql: "database",
  openai: "codex",
  opencode: "agents",
  postgresql: "postgres",
  rs: "rust",
  scss: "sass",
  sh: "shell",
  sqlite: "database",
  ts: "typescript",
  tsx: "react",
  typescriptreact: "react",
};

const SIMPLE_ICON_COLOR = "8B8F99";

function isBuiltInDatabaseProvider(providerId: string): boolean {
  return providerId === "sqlite";
}

function resolvePackageSize(manifest: {
  installation?: {
    size?: number;
    platformArch?: Record<string, { size?: number }>;
  };
}): number | undefined {
  const platformSize = manifest.installation?.platformArch?.[PLATFORM_ARCH]?.size;
  if (typeof platformSize === "number" && platformSize > 0) return platformSize;
  const size = manifest.installation?.size;
  return typeof size === "number" && size > 0 ? size : undefined;
}

function getErrorMessage(error: unknown, fallback = "Unknown error"): string {
  if (error instanceof Error) return error.message || fallback;
  if (typeof error === "string") return error || fallback;
  return String(error || fallback);
}

const getCategoryLabel = (category: UnifiedExtension["category"], t: Translator) => {
  return t(`extensions.category.${category}`);
};

function getPrimaryActionLabel(extension: UnifiedExtension, t: Translator): string {
  if (isAppearanceExtension(extension)) {
    if (extension.isInstalled) {
      if (!extension.isEnabled) return t("extensions.activate");
      return extension.isActive ? t("extensions.current") : t("extensions.use");
    }

    return t("extensions.install");
  }

  if (extension.category === "skill") {
    return extension.isInstalled ? t("extensions.remove") : t("extensions.add");
  }

  if (extension.category === "agent") {
    return extension.isInstalled ? t("extensions.uninstall") : t("extensions.install");
  }

  return extension.isInstalled
    ? extension.isEnabled
      ? t("extensions.deactivate")
      : t("extensions.activate")
    : t("extensions.install");
}

function isAppearanceExtension(extension: UnifiedExtension): boolean {
  return extension.category === "theme" || extension.category === "icon-theme";
}

function getAppearanceSettingKey(extension: UnifiedExtension): "theme" | "iconTheme" | null {
  if (extension.category === "theme") return "theme";
  if (extension.category === "icon-theme") return "iconTheme";
  return null;
}

function getAppearanceOptionLabel(extension: UnifiedExtension, optionId: string): string {
  return (
    extension.appearanceOptions?.find((option) => option.id === optionId)?.name ?? extension.name
  );
}

function canDeactivateAppearanceExtension(extension: UnifiedExtension): boolean {
  return Boolean(
    isAppearanceExtension(extension) &&
    extension.isInstalled &&
    extension.isEnabled &&
    !extension.isBundled,
  );
}

function normalizeIconLookupKey(value: string | undefined | null): string {
  return (value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9+#]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function stripGenericIconLookupTerms(value: string): string {
  return normalizeIconLookupKey(
    value.replace(/\b(?:provider|language support|language|theme|icons?|cli|code)\b/g, " "),
  );
}

function getIconLookupCandidates(iconId: string | undefined | null): string[] {
  const normalized = normalizeIconLookupKey(iconId);
  if (!normalized) return [];

  const stripped = stripGenericIconLookupTerms(normalized.replace(/-/g, " "));
  const baseCandidates = [
    normalized,
    stripped,
    normalized.replace(/-/g, ""),
    stripped.replace(/-/g, ""),
  ].filter(Boolean);

  return Array.from(
    new Set(
      baseCandidates.flatMap((candidate) => [
        candidate,
        LOCAL_ICON_ALIASES[candidate],
        SIMPLE_ICON_SLUGS[candidate],
      ]),
    ),
  ).filter(Boolean) as string[];
}

function getLocalFileIconUrl(iconId: string | undefined | null): string | undefined {
  const candidates = getIconLookupCandidates(iconId);

  for (const candidate of candidates) {
    const url = LOCAL_FILE_ICON_URLS.get(candidate);
    if (url) return url;
  }

  return undefined;
}

function getSimpleIconUrl(iconId: string | undefined | null): string | undefined {
  const candidates = getIconLookupCandidates(iconId);
  const slug = candidates.find((candidate) => SIMPLE_ICON_SLUGS[candidate]);

  return slug
    ? `https://cdn.simpleicons.org/${SIMPLE_ICON_SLUGS[slug]}/${SIMPLE_ICON_COLOR}`
    : undefined;
}

function getCatalogIconUrl(...iconIds: Array<string | undefined | null>): string | undefined {
  for (const iconId of iconIds) {
    const simpleIcon = getSimpleIconUrl(iconId);
    if (simpleIcon) return simpleIcon;

    const localIcon = getLocalFileIconUrl(iconId);
    if (localIcon) return localIcon;
  }

  return undefined;
}

function resolveManifestIcon(
  manifestIcon: string | undefined,
  ...fallbackIconIds: Array<string | undefined | null>
): string | undefined {
  const trimmedIcon = manifestIcon?.trim();
  const resolvedFallback = getCatalogIconUrl(...fallbackIconIds);
  const iconFileName = trimmedIcon?.split(/[?#]/)[0]?.split("/").pop()?.toLowerCase();

  if (!trimmedIcon || iconFileName === "icon.svg") {
    return resolvedFallback ?? trimmedIcon;
  }

  return trimmedIcon;
}

function getCategoryIcon(category: UnifiedExtension["category"]): ReactNode {
  const className = "size-4 text-subtle-foreground";

  switch (category) {
    case "language":
      return <TextT className={className} weight="duotone" />;
    case "theme":
      return <PaintBrush className={className} weight="duotone" />;
    case "icon-theme":
      return <Package className={className} weight="duotone" />;
    case "database":
      return <Database className={className} weight="duotone" />;
    case "ai":
      return <Sparkles className={className} weight="duotone" />;
    case "integration":
      return <PlugsConnected className={className} weight="duotone" />;
    case "skill":
      return <Brain className={className} weight="duotone" />;
    case "agent":
      return <Robot className={className} weight="duotone" />;
  }
}

function isImageIcon(icon: string): boolean {
  return (
    /^(?:[a-z]+:)?\/\//i.test(icon) ||
    icon.startsWith("/") ||
    icon.startsWith("data:") ||
    /\.(?:svg|png|jpe?g|webp)(?:[?#].*)?$/i.test(icon)
  );
}

function isNamedIcon(icon: string): boolean {
  return !icon.includes("/") && !/\.(?:svg|png|jpe?g|webp)(?:[?#].*)?$/i.test(icon);
}

function ExtensionIcon({ extension }: { extension: UnifiedExtension }) {
  const [failedImageIcon, setFailedImageIcon] = useState(false);
  const icon = extension.icon?.trim();
  const showImageIcon = Boolean(icon && isImageIcon(icon) && !failedImageIcon);
  const showNamedIcon = Boolean(icon && !isImageIcon(icon) && isNamedIcon(icon));

  useEffect(() => {
    setFailedImageIcon(false);
  }, [icon]);

  return (
    <span
      className={cn(
        "flex h-12 w-12 shrink-0 items-center justify-center rounded-lg border border-border/60",
        showImageIcon ? "bg-white/95" : "bg-background",
      )}
    >
      {showImageIcon ? (
        <img
          alt=""
          className="size-7 object-contain"
          draggable={false}
          src={icon}
          onError={() => setFailedImageIcon(true)}
        />
      ) : showNamedIcon && icon ? (
        <DynamicIcon name={icon} className="size-5 text-subtle-foreground" />
      ) : (
        getCategoryIcon(extension.category)
      )}
    </span>
  );
}

const ExtensionRow = ({
  extension,
  onToggle,
  onUpdate,
  onContextMenu,
  onSelect,
  selected,
  isInstalling,
  hasUpdate,
  hasRuntimeIssue,
}: {
  extension: UnifiedExtension;
  onToggle: () => void;
  onUpdate?: () => void;
  onContextMenu: (event: MouseEvent<HTMLDivElement>, extension: UnifiedExtension) => void;
  onSelect: () => void;
  selected?: boolean;
  isInstalling?: boolean;
  hasUpdate?: boolean;
  hasRuntimeIssue?: boolean;
}) => {
  const { t } = useTranslation();
  const primaryActionLabel = getPrimaryActionLabel(extension, t);
  const isUnavailableAgent =
    extension.category === "agent" && !extension.isInstalled && extension.canInstall === false;
  const actionContent = isInstalling ? (
    <span className="flex h-8 w-8 shrink-0 items-center justify-center text-primary">
      <Spinner label={t("extensions.installing", { name: extension.name })} compact />
    </span>
  ) : hasRuntimeIssue && onUpdate ? (
    <Button
      onClick={(event) => {
        event.stopPropagation();
        onUpdate();
      }}
      variant="default"
      tooltip={t("extensions.reinstall")}
      size="icon"
      className="text-destructive"
    >
      <WarningCircle className="size-4" weight="duotone" />
    </Button>
  ) : hasUpdate && onUpdate ? (
    <Button
      onClick={(event) => {
        event.stopPropagation();
        onUpdate();
      }}
      variant="default"
      tooltip={t("extensions.update")}
      size="icon"
    >
      <RefreshCw className="size-4" weight="duotone" />
    </Button>
  ) : isUnavailableAgent ? (
    <Button disabled variant="ghost" tooltip={t("extensions.unavailable")} size="icon">
      <XCircle className="size-4" weight="duotone" />
    </Button>
  ) : extension.isInstalled ? (
    <span
      className="flex h-8 w-8 shrink-0 items-center justify-center text-subtle-foreground"
      aria-label={extension.isBundled ? t("extensions.builtIn") : t("extensions.installed")}
    >
      <Check className="size-4" weight="bold" />
    </span>
  ) : (
    <Button
      onClick={(event) => {
        event.stopPropagation();
        onToggle();
      }}
      variant="default"
      tooltip={primaryActionLabel}
      size="icon"
    >
      <Plus className="size-4" weight="bold" />
    </Button>
  );

  return (
    <div
      className={cn(
        "group flex min-h-16 min-w-0 items-center gap-3 rounded-lg px-2.5 py-2 text-left text-subtle-foreground transition-colors",
        "hover:bg-accent/70 hover:text-foreground focus-within:bg-accent/70",
        selected && "bg-accent/80 text-foreground",
      )}
      onClick={onSelect}
      onContextMenu={(event) => onContextMenu(event, extension)}
      role="button"
      tabIndex={0}
      aria-pressed={selected}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
    >
      <ExtensionIcon extension={extension} />
      <div className="min-w-0 flex-1">
        <div className="truncate font-medium text-foreground ui-text-sm">{extension.name}</div>
        {extension.description ? (
          <div className="mt-0.5 truncate text-subtle-foreground ui-text-sm">
            {extension.description}
          </div>
        ) : null}
      </div>
      <div className="ml-auto flex shrink-0 items-center justify-center">{actionContent}</div>
    </div>
  );
};

export const ExtensionsSidebar = () => {
  const { t } = useTranslation();
  const settings = useSettingsStore(
    useShallow((state) => ({
      aiSkills: state.settings.aiSkills,
      extensionsActiveTab: state.settings.extensionsActiveTab,
      iconTheme: state.settings.iconTheme,
      theme: state.settings.theme,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const [searchQuery, setSearchQuery] = useState("");
  const searchInputRef = useRef<HTMLInputElement>(null);
  const [extensions, setExtensions] = useState<UnifiedExtension[]>([]);
  const [marketplaceSkills, setMarketplaceSkills] = useState<MarketplaceSkill[]>([]);
  const [isLoadingSkills, setIsLoadingSkills] = useState(false);
  const [agents, setAgents] = useState<AgentConfig[]>([]);
  const [isLoadingAgents, setIsLoadingAgents] = useState(false);
  const [installingAgentIds, setInstallingAgentIds] = useState<Set<string>>(new Set());
  const [isSkillsCommandOpen, setIsSkillsCommandOpen] = useState(false);
  const [selectedExtensionId, setSelectedExtensionId] = useState<string | null>(null);
  const { showToast } = useToast();
  const extensionContextMenu = useDropdownMenu<UnifiedExtension>();

  const availableExtensions = useExtensionStore.use.availableExtensions();
  const extensionsWithUpdates = useExtensionStore.use.extensionsWithUpdates();
  const {
    installExtension,
    uninstallExtension,
    enableExtension,
    disableExtension,
    updateExtension,
  } = useExtensionStore.use.actions();

  useEffect(() => {
    if (!FILTER_TAB_IDS.has(settings.extensionsActiveTab)) {
      void updateSetting("extensionsActiveTab", "all");
    }
  }, [settings.extensionsActiveTab, updateSetting]);

  useEffect(() => {
    searchInputRef.current?.focus();
  }, []);

  const loadAgents = useCallback(async () => {
    setIsLoadingAgents(true);
    try {
      const availableAgents = await invoke<AgentConfig[]>("get_available_agents");
      setAgents(availableAgents);
    } catch (error) {
      console.error("Failed to load ACP agents:", error);
      setAgents([]);
    } finally {
      setIsLoadingAgents(false);
    }
  }, []);

  const loadAllExtensions = useCallback(() => {
    const allExtensions: UnifiedExtension[] = [];
    const detectedAgents = new Map(agents.map((agent) => [agent.id, agent]));

    for (const [, ext] of availableExtensions) {
      if (ext.manifest.agents && ext.manifest.agents.length > 0) {
        const contribution = ext.manifest.agents[0];
        const agent = detectedAgents.get(contribution.id);
        allExtensions.push({
          id: `agent:${contribution.id}`,
          name: agent?.name ?? contribution.name,
          description:
            agent?.description ??
            contribution.description ??
            t("extensions.agentFallbackDescription"),
          category: "agent",
          isInstalled: agent?.installed ?? false,
          isEnabled: agent?.installed ?? false,
          version: ext.manifest.version,
          extensions: [agent?.binaryName ?? contribution.binaryName],
          publisher: ext.manifest.publisher,
          isMarketplace: true,
          isBundled: false,
          runtimeIssues: ext.runtimeIssues,
          agentId: contribution.id,
          icon: resolveManifestIcon(
            agent?.icon ?? contribution.icon ?? ext.manifest.icon,
            contribution.id,
            agent?.id,
            agent?.name,
            contribution.name,
            contribution.binaryName,
            ext.manifest.displayName,
          ),
          canInstall: agent?.canInstall ?? Boolean(contribution.install),
          contributionSummary: [
            `agent:${contribution.id}`,
            agent?.binaryName ?? contribution.binaryName,
          ].filter(Boolean),
        });
      }

      if (ext.manifest.languages && ext.manifest.languages.length > 0) {
        const lang = ext.manifest.languages[0];
        const isBundled = !ext.manifest.installation;
        allExtensions.push({
          id: ext.manifest.id,
          name: ext.manifest.displayName,
          description: ext.manifest.description,
          category: "language",
          isInstalled: ext.isInstalled,
          isEnabled: ext.isEnabled,
          version: ext.manifest.version,
          extensions: lang.extensions.map((e: string) => e.replace(".", "")),
          publisher: ext.manifest.publisher,
          isMarketplace: !isBundled,
          isBundled,
          icon: resolveManifestIcon(
            ext.manifest.icon,
            lang.id,
            lang.aliases?.[0],
            lang.extensions[0],
            ext.manifest.displayName,
            ext.manifest.name,
          ),
          runtimeIssues: ext.runtimeIssues,
          packageSize: resolvePackageSize(ext.manifest),
          contributionSummary: [
            ...ext.manifest.languages.map((language) => `language:${language.id}`),
            ...(ext.manifest.lsp?.name ? [`lsp:${ext.manifest.lsp.name}`] : []),
            ...(ext.manifest.formatter?.name ? [`formatter:${ext.manifest.formatter.name}`] : []),
            ...(ext.manifest.linter?.name ? [`linter:${ext.manifest.linter.name}`] : []),
          ],
        });
      }

      const databaseContributions = getManifestDatabaseContributions(ext.manifest);
      if (databaseContributions.length > 0) {
        const provider = databaseContributions[0];
        const isBuiltInDatabase = isBuiltInDatabaseProvider(provider.id);
        allExtensions.push({
          id: ext.manifest.id,
          name: ext.manifest.displayName,
          description: ext.manifest.description,
          category: "database",
          isInstalled: ext.isInstalled,
          isEnabled: ext.isEnabled,
          version: ext.manifest.version,
          extensions: provider.fileExtensions?.map((item) => item.replace(".", "")),
          publisher: ext.manifest.publisher,
          isMarketplace: !isBuiltInDatabase,
          isBundled: isBuiltInDatabase,
          icon: resolveManifestIcon(
            ext.manifest.icon,
            provider.id,
            provider.label,
            ext.manifest.displayName,
          ),
          runtimeIssues: ext.runtimeIssues,
          packageSize: resolvePackageSize(ext.manifest),
          contributionSummary: [`database:${provider.id}`],
        });
      }

      const themeContributions = getManifestThemeContributions(ext.manifest);
      if (themeContributions.length > 0) {
        const themeIds = themeContributions.map((theme) => theme.id);
        const activeThemeId = themeIds.find((themeId) => themeId === settings.theme);
        const themeId = activeThemeId ?? themeIds[0] ?? ext.manifest.id;
        allExtensions.push({
          id: ext.manifest.id,
          name: ext.manifest.displayName,
          description: ext.manifest.description,
          category: "theme",
          isInstalled: ext.isInstalled,
          isActive: ext.isEnabled && Boolean(activeThemeId),
          isEnabled: ext.isEnabled,
          version: ext.manifest.version,
          publisher: ext.manifest.publisher,
          isMarketplace: true,
          isBundled: false,
          icon: resolveManifestIcon(
            ext.manifest.icon,
            activeThemeId,
            themeContributions[0]?.id,
            themeContributions[0]?.name,
            ext.manifest.displayName,
            "theme",
          ),
          runtimeIssues: ext.runtimeIssues,
          packageSize: resolvePackageSize(ext.manifest),
          selectionId: themeId,
          appearanceOptions: themeContributions.map((theme) => ({
            id: theme.id,
            name: theme.name,
            description: theme.description,
          })),
          contributionSummary: themeContributions.map((theme) => `theme:${theme.id}`),
        });
      }

      const iconContributions = getManifestIconContributions(ext.manifest);
      if (iconContributions.length > 0) {
        const iconThemeIds = iconContributions.map((theme) => theme.id);
        const activeIconThemeId = iconThemeIds.find((themeId) => themeId === settings.iconTheme);
        const iconThemeId = activeIconThemeId ?? iconThemeIds[0] ?? ext.manifest.id;
        allExtensions.push({
          id: ext.manifest.id,
          name: ext.manifest.displayName,
          description: ext.manifest.description,
          category: "icon-theme",
          isInstalled: ext.isInstalled,
          isActive: ext.isEnabled && Boolean(activeIconThemeId),
          isEnabled: ext.isEnabled,
          version: ext.manifest.version,
          publisher: ext.manifest.publisher,
          isMarketplace: true,
          isBundled: false,
          icon: resolveManifestIcon(
            ext.manifest.icon,
            iconContributions[0]?.id,
            iconContributions[0]?.name,
            ext.manifest.displayName,
            "icon-theme",
          ),
          runtimeIssues: ext.runtimeIssues,
          packageSize: resolvePackageSize(ext.manifest),
          selectionId: iconThemeId,
          appearanceOptions: iconContributions.map((theme) => ({
            id: theme.id,
            name: theme.name,
            description: theme.description,
          })),
          contributionSummary: iconContributions.map((theme) => `icon:${theme.id}`),
        });
      }

      const aiProviderContributions = getManifestAIProviderContributions(ext.manifest);
      if (aiProviderContributions.length > 0) {
        allExtensions.push({
          id: ext.manifest.id,
          name: ext.manifest.displayName,
          description: ext.manifest.description,
          category: "ai",
          isInstalled: ext.isInstalled,
          isEnabled: ext.isEnabled,
          version: ext.manifest.version,
          publisher: ext.manifest.publisher,
          isMarketplace: true,
          isBundled: false,
          icon: resolveManifestIcon(
            ext.manifest.icon,
            aiProviderContributions[0]?.id,
            aiProviderContributions[0]?.name,
            ext.manifest.displayName,
          ),
          runtimeIssues: ext.runtimeIssues,
          packageSize: resolvePackageSize(ext.manifest),
          contributionSummary: aiProviderContributions.map((provider) => `provider:${provider.id}`),
        });
      }

      const integrationContributions = getManifestIntegrationContributions(ext.manifest);
      if (integrationContributions.length > 0) {
        const integration = integrationContributions[0];
        allExtensions.push({
          id: ext.manifest.id,
          name: ext.manifest.displayName,
          description: ext.manifest.description,
          category: "integration",
          isInstalled: ext.isInstalled,
          isEnabled: ext.isEnabled,
          version: ext.manifest.version,
          publisher: ext.manifest.publisher,
          isMarketplace: true,
          isBundled: false,
          icon: resolveManifestIcon(
            ext.manifest.icon,
            integration.icon,
            integration.id,
            integration.name,
          ),
          runtimeIssues: ext.runtimeIssues,
          packageSize: resolvePackageSize(ext.manifest),
          contributionSummary: integrationContributions.map((item) => `integration:${item.id}`),
        });
      }
    }

    themeRegistry.getAllThemes().forEach((theme) => {
      if (themeRegistry.getThemeSource(theme.id)) {
        return;
      }

      allExtensions.push({
        id: theme.id,
        name: theme.name,
        description:
          theme.description || t("extensions.themeFallbackDescription", { category: theme.category }),
        category: "theme",
        isInstalled: true,
        isEnabled: true,
        isActive: settings.theme === theme.id,
        version: "1.0.0",
        icon: getCatalogIconUrl(theme.id, theme.name, "theme"),
        selectionId: theme.id,
        appearanceOptions: [
          {
            id: theme.id,
            name: theme.name,
            description: theme.description,
          },
        ],
      });
    });

    getVisibleIconThemes(iconThemeRegistry.getAllThemes()).forEach((iconTheme) => {
      if (iconThemeRegistry.getThemeSource(iconTheme.id)) {
        return;
      }

      allExtensions.push({
        id: iconTheme.id,
        name: iconTheme.name,
        description:
          iconTheme.description ||
          t("extensions.iconThemeFallbackDescription", { name: iconTheme.name }),
        category: "icon-theme",
        isInstalled: true,
        isEnabled: true,
        isActive: settings.iconTheme === iconTheme.id,
        version: "1.0.0",
        icon: getCatalogIconUrl(iconTheme.id, iconTheme.name, "icon-theme"),
        selectionId: iconTheme.id,
        appearanceOptions: [
          {
            id: iconTheme.id,
            name: iconTheme.name,
            description: iconTheme.description,
          },
        ],
      });
    });

    for (const skill of settings.aiSkills) {
      const preview = skill.content.trim().replace(/\s+/g, " ").slice(0, 160);
      const marketplaceSkill =
        skill.source === "marketplace"
          ? marketplaceSkills.find(
              (candidate) => candidate.id === skill.sourceId || candidate.id === skill.id,
            )
          : undefined;

      allExtensions.push({
        id: skill.id,
        name: skill.title,
        description: skill.description || preview || t("extensions.reusableSkillDescription"),
        category: "skill",
        isInstalled: true,
        isEnabled: true,
        version:
          skill.version || (skill.source === "marketplace" ? undefined : t("extensions.local")),
        publisher:
          skill.author ||
          (skill.source === "marketplace" ? t("extensions.marketplace") : t("extensions.you")),
        isMarketplace: skill.source === "marketplace",
        icon: getCatalogIconUrl(skill.title, skill.author, "codex"),
        skill,
        marketplaceSkill,
        contributionSummary: ["skill"],
      });
    }

    for (const skill of marketplaceSkills) {
      if (isMarketplaceSkillInstalled(settings.aiSkills, skill.id)) {
        continue;
      }

      allExtensions.push({
        id: skill.id,
        name: skill.title,
        description: skill.description,
        category: "skill",
        isInstalled: false,
        isEnabled: false,
        version: skill.version,
        publisher: skill.author,
        isMarketplace: true,
        icon: getCatalogIconUrl(skill.title, skill.author, "codex"),
        marketplaceSkill: skill,
        contributionSummary: ["skill"],
      });
    }

    const agentIds = new Set(
      allExtensions
        .filter((extension) => extension.category === "agent")
        .map((extension) => extension.agentId ?? extension.id.replace(/^agent:/, "")),
    );
    for (const agent of agents) {
      if (agentIds.has(agent.id)) {
        continue;
      }

      allExtensions.push({
        id: `agent:${agent.id}`,
        name: agent.name,
        description: agent.description ?? t("extensions.agentFallbackDescription"),
        category: "agent",
        isInstalled: agent.installed,
        isEnabled: agent.installed,
        extensions: [agent.binaryName],
        publisher: t("extensions.marketplace"),
        isMarketplace: true,
        agentId: agent.id,
        icon: resolveManifestIcon(agent.icon ?? undefined, agent.id, agent.name, agent.binaryName),
        canInstall: agent.canInstall,
        contributionSummary: [`agent:${agent.id}`, agent.binaryName],
      });
    }

    setExtensions(allExtensions);
  }, [
    agents,
    availableExtensions,
    marketplaceSkills,
    settings.aiSkills,
    settings.iconTheme,
    settings.theme,
    t,
  ]);

  useEffect(() => {
    loadAllExtensions();
  }, [loadAllExtensions]);

  useEffect(() => {
    void loadAgents();
  }, [loadAgents]);

  useEffect(() => {
    setIsLoadingSkills(true);
    void loadMarketplaceSkills()
      .then(setMarketplaceSkills)
      .finally(() => setIsLoadingSkills(false));
  }, []);

  const handleUpdate = async (extension: UnifiedExtension) => {
    if (extension.category === "skill") {
      if (!extension.skill || !extension.marketplaceSkill) return;

      try {
        const updatedSkill = updateSkillFromMarketplace(
          extension.skill,
          extension.marketplaceSkill,
        );
        await updateSetting(
          "aiSkills",
          settings.aiSkills.map((skill) =>
            skill.id === extension.skill?.id ? updatedSkill : skill,
          ),
        );
        showToast({
          message: updatedSkill.localOverride
            ? t("extensions.updatedWithLocalOverride", { name: extension.name })
            : t("extensions.updatedSuccessfully", { name: extension.name }),
          type: "success",
          duration: 3000,
        });
      } catch (error) {
        console.error(`Failed to update ${extension.name}:`, error);
        showToast({
          message: t("extensions.updateFailed", {
            name: extension.name,
            message: getErrorMessage(error, t("extensions.unknownError")),
          }),
          type: "error",
          duration: 5000,
        });
      }
      return;
    }

    try {
      await updateExtension(extension.id);
      showToast({
        message: t("extensions.updatedSuccessfully", { name: extension.name }),
        type: "success",
        duration: 3000,
      });
    } catch (error) {
      console.error(`Failed to update ${extension.name}:`, error);
      showToast({
        message: t("extensions.updateFailed", {
          name: extension.name,
          message: getErrorMessage(error, t("extensions.unknownError")),
        }),
        type: "error",
        duration: 5000,
      });
    }
  };

  const handleResetSkillOverride = async (extension: UnifiedExtension) => {
    if (extension.category !== "skill" || !extension.skill) return;

    try {
      await updateSetting(
        "aiSkills",
        settings.aiSkills.map((skill) =>
          skill.id === extension.skill?.id ? resetSkillLocalOverride(skill) : skill,
        ),
      );
      showToast({
        message: t("extensions.resetToMarketplaceSuccess", { name: extension.name }),
        type: "success",
        duration: 3000,
      });
    } catch (error) {
      console.error(`Failed to reset ${extension.name}:`, error);
      showToast({
        message: t("extensions.resetFailed", {
          name: extension.name,
          message: getErrorMessage(error, t("extensions.unknownError")),
        }),
        type: "error",
        duration: 5000,
      });
    }
  };

  const handleUseAppearance = async (extension: UnifiedExtension, selectionId?: string) => {
    const settingKey = getAppearanceSettingKey(extension);
    if (!settingKey || !extension.isInstalled) {
      return;
    }

    const nextSelectionId = selectionId ?? extension.selectionId ?? extension.id;

    try {
      if (!extension.isEnabled) {
        await enableExtension(extension.id);
      }
      await updateSetting(settingKey, nextSelectionId);
      showToast({
        message: t("extensions.selected", {
          name: getAppearanceOptionLabel(extension, nextSelectionId),
        }),
        type: "success",
        duration: 2500,
      });
    } catch (error) {
      console.error(`Failed to use ${extension.name}:`, error);
      showToast({
        message: t("extensions.useFailed", {
          name: extension.name,
          message: getErrorMessage(error, t("extensions.unknownError")),
        }),
        type: "error",
        duration: 5000,
      });
    }
    setTimeout(() => loadAllExtensions(), 100);
  };

  const handleActivateExtension = async (extension: UnifiedExtension) => {
    if (!extension.isInstalled || extension.isEnabled) {
      return;
    }

    try {
      await enableExtension(extension.id);
      showToast({
        message: t("extensions.activated", { name: extension.name }),
        type: "success",
        duration: 2500,
      });
    } catch (error) {
      console.error(`Failed to activate ${extension.name}:`, error);
      showToast({
        message: t("extensions.activateFailed", {
          name: extension.name,
          message: getErrorMessage(error, t("extensions.unknownError")),
        }),
        type: "error",
        duration: 5000,
      });
    }
    setTimeout(() => loadAllExtensions(), 100);
  };

  const handleDeactivateExtension = async (extension: UnifiedExtension) => {
    if (!extension.isInstalled || !extension.isEnabled) {
      return;
    }

    try {
      await disableExtension(extension.id);
      showToast({
        message: t("extensions.deactivated", { name: extension.name }),
        type: "success",
        duration: 2500,
      });
    } catch (error) {
      console.error(`Failed to deactivate ${extension.name}:`, error);
      showToast({
        message: t("extensions.deactivateFailed", {
          name: extension.name,
          message: getErrorMessage(error, t("extensions.unknownError")),
        }),
        type: "error",
        duration: 5000,
      });
    }
    setTimeout(() => loadAllExtensions(), 100);
  };

  const handleToggle = async (extension: UnifiedExtension) => {
    if (extension.category === "agent") {
      if (!extension.isInstalled && extension.canInstall === false) {
        showToast({
          message: t("extensions.cannotInstallAutomatically", { name: extension.name }),
          type: "error",
          duration: 5000,
        });
        return;
      }

      const agentId = extension.agentId ?? extension.id.replace(/^agent:/, "");
      setInstallingAgentIds((current) => new Set(current).add(agentId));

      try {
        const installedAgent = await invoke<AgentConfig>(
          extension.isInstalled ? "uninstall_acp_agent" : "install_acp_agent",
          { agentId },
        );
        setAgents((current) => {
          const next = new Map(current.map((agent) => [agent.id, agent]));
          next.set(installedAgent.id, installedAgent);
          return Array.from(next.values());
        });
        void loadAgents();
        const managedUninstallLeftGlobalBinary = extension.isInstalled && installedAgent.installed;
        showToast({
          message: extension.isInstalled
            ? managedUninstallLeftGlobalBinary
              ? t("extensions.managedInstallRemoved", { name: extension.name })
              : t("extensions.uninstalledSuccessfully", { name: extension.name })
            : t("extensions.installedSuccessfully", { name: extension.name }),
          description: managedUninstallLeftGlobalBinary
            ? t("extensions.globalInstallStillDetected")
            : undefined,
          type: managedUninstallLeftGlobalBinary ? "info" : "success",
          duration: managedUninstallLeftGlobalBinary ? 5000 : 3000,
        });
      } catch (error) {
        console.error(
          `Failed to ${extension.isInstalled ? "uninstall" : "install"} ${extension.name}:`,
          error,
        );
        showToast({
          message: extension.isInstalled
            ? t("extensions.uninstallFailed", {
                name: extension.name,
                message: getErrorMessage(error, t("extensions.unknownError")),
              })
            : t("extensions.installFailed", {
                message: `${extension.name}: ${getErrorMessage(error, t("extensions.unknownError"))}`,
              }),
          type: "error",
          duration: 5000,
        });
      } finally {
        setInstallingAgentIds((current) => {
          const next = new Set(current);
          next.delete(agentId);
          return next;
        });
      }
      return;
    }

    if (extension.category === "skill") {
      try {
        if (extension.isInstalled) {
          const sourceId = extension.skill?.sourceId;
          await updateSetting(
            "aiSkills",
            settings.aiSkills.filter(
              (skill) => skill.id !== extension.id && (!sourceId || skill.sourceId !== sourceId),
            ),
          );
          showToast({
            message: t("extensions.removedSuccessfully", { name: extension.name }),
            type: "success",
            duration: 3000,
          });
          return;
        }

        if (!extension.marketplaceSkill) {
          return;
        }

        await updateSetting("aiSkills", [
          createSkillFromMarketplace(extension.marketplaceSkill),
          ...settings.aiSkills,
        ]);
        showToast({
          message: t("extensions.addedSuccessfully", { name: extension.name }),
          type: "success",
          duration: 3000,
        });
      } catch (error) {
        console.error(`Failed to update ${extension.name}:`, error);
        showToast({
          message: t("extensions.updateActionFailed", {
            name: extension.name,
            message: getErrorMessage(error, t("extensions.unknownError")),
          }),
          type: "error",
          duration: 5000,
        });
      }
      return;
    }

    if (isAppearanceExtension(extension) && extension.isInstalled) {
      if (!extension.isEnabled) {
        await handleActivateExtension(extension);
        return;
      }

      if (extension.isActive) {
        return;
      }

      await handleUseAppearance(extension);
      return;
    }

    if (extension.isInstalled) {
      try {
        if (extension.isEnabled) {
          await disableExtension(extension.id);
        } else {
          await enableExtension(extension.id);
        }
        showToast({
          message: extension.isEnabled
            ? t("extensions.deactivated", { name: extension.name })
            : t("extensions.activated", { name: extension.name }),
          type: "success",
          duration: 2500,
        });
      } catch (error) {
        console.error(
          `Failed to ${extension.isEnabled ? "deactivate" : "activate"} ${extension.name}:`,
          error,
        );
        showToast({
          message: extension.isEnabled
            ? t("extensions.deactivateFailed", {
                name: extension.name,
                message: getErrorMessage(error, t("extensions.unknownError")),
              })
            : t("extensions.activateFailed", {
                name: extension.name,
                message: getErrorMessage(error, t("extensions.unknownError")),
              }),
          type: "error",
          duration: 5000,
        });
      }
      setTimeout(() => loadAllExtensions(), 100);
      return;
    }

    if (extension.isMarketplace) {
      try {
        await installExtension(extension.id);
        showToast({
          message: t("extensions.installedSuccessfully", { name: extension.name }),
          type: "success",
          duration: 3000,
        });
      } catch (error) {
        console.error(`Failed to install ${extension.name}:`, error);
        showToast({
          message: t("extensions.installFailed", {
            message: `${extension.name}: ${getErrorMessage(error, t("extensions.unknownError"))}`,
          }),
          type: "error",
          duration: 5000,
        });
      }
      return;
    }

    setTimeout(() => loadAllExtensions(), 100);
  };

  const handleUninstall = async (extension: UnifiedExtension) => {
    if (extension.category === "agent" || extension.category === "skill") {
      await handleToggle(extension);
      return;
    }

    if (!extension.isMarketplace || !extension.isInstalled) {
      return;
    }

    try {
      await uninstallExtension(extension.id);
      showToast({
        message: t("extensions.uninstalledSuccessfully", { name: extension.name }),
        type: "success",
        duration: 3000,
      });
    } catch (error) {
      console.error(`Failed to uninstall ${extension.name}:`, error);
      showToast({
        message: t("extensions.uninstallFailed", {
          name: extension.name,
          message: getErrorMessage(error, t("extensions.unknownError")),
        }),
        type: "error",
        duration: 5000,
      });
    }
  };

  const normalizedSearchQuery = searchQuery.trim().toLowerCase();
  const searchMatchedExtensions = extensions.filter((extension) => {
    const matchesSearch =
      !normalizedSearchQuery ||
      extension.name.toLowerCase().includes(normalizedSearchQuery) ||
      extension.description.toLowerCase().includes(normalizedSearchQuery) ||
      extension.publisher?.toLowerCase().includes(normalizedSearchQuery) ||
      extension.contributionSummary?.some((item) =>
        item.toLowerCase().includes(normalizedSearchQuery),
      );
    return matchesSearch;
  });
  const filterCounts = FILTER_TABS.reduce(
    (counts, tab) => {
      counts[tab.id] =
        tab.id === "all"
          ? searchMatchedExtensions.length
          : searchMatchedExtensions.filter((extension) => extension.category === tab.id).length;
      return counts;
    },
    {} as Record<ExtensionTabId, number>,
  );
  const filteredExtensions = searchMatchedExtensions.filter((extension) => {
    const matchesTab =
      settings.extensionsActiveTab === "all" || extension.category === settings.extensionsActiveTab;
    return matchesTab;
  });
  const selectedExtension =
    filteredExtensions.find((extension) => extension.id === selectedExtensionId) ??
    filteredExtensions[0] ??
    null;
  const installedCount = extensions.filter((extension) => extension.isInstalled).length;

  useEffect(() => {
    if (filteredExtensions.length === 0) {
      if (selectedExtensionId !== null) setSelectedExtensionId(null);
      return;
    }

    if (
      !selectedExtensionId ||
      !filteredExtensions.some((item) => item.id === selectedExtensionId)
    ) {
      setSelectedExtensionId(filteredExtensions[0]?.id ?? null);
    }
  }, [filteredExtensions, selectedExtensionId]);

  const isExtensionInstalling = (extension: UnifiedExtension) =>
    Boolean(
      availableExtensions.get(extension.id)?.isInstalling ||
      (extension.category === "agent" &&
        installingAgentIds.has(extension.agentId ?? extension.id.replace(/^agent:/, ""))),
    );

  const hasExtensionUpdate = (extension: UnifiedExtension) =>
    extensionsWithUpdates.has(extension.id) ||
    Boolean(
      extension.skill &&
      extension.marketplaceSkill &&
      hasMarketplaceSkillUpdate(extension.skill, extension.marketplaceSkill),
    );
  const updateCount = extensions.filter((extension) => hasExtensionUpdate(extension)).length;

  const handleExtensionContextMenu = useCallback(
    (event: MouseEvent<HTMLDivElement>, extension: UnifiedExtension) => {
      extensionContextMenu.open(event, extension);
    },
    [extensionContextMenu],
  );

  const extensionContextMenuItems = useMemo<MenuItem[]>(() => {
    const extension = extensionContextMenu.data;
    if (!extension) return [];

    const items: MenuItem[] = [];
    const isInstalling = isExtensionInstalling(extension);
    const hasUpdate = hasExtensionUpdate(extension);
    const hasLocalOverride = extension.skill ? hasSkillLocalOverride(extension.skill) : false;
    const hasRuntimeIssue = Boolean(extension.runtimeIssues?.length);
    const isUnavailableAgent =
      extension.category === "agent" && !extension.isInstalled && extension.canInstall === false;
    const isAppearance = isAppearanceExtension(extension);
    const primaryActionLabel = getPrimaryActionLabel(extension, t);

    if (extension.isBundled) {
      items.push({
        id: "built-in",
        label: t("extensions.builtIn"),
        icon: <Check className="size-3.5 text-primary" />,
        disabled: true,
        onClick: () => {},
      });
      return items;
    }

    if (extension.isInstalled && extension.category !== "agent" && extension.category !== "skill") {
      if (isAppearance) {
        if (!extension.isEnabled) {
          items.push({
            id: "activate",
            label: t("extensions.activate"),
            icon: <Check className="size-3.5 text-primary" weight="bold" />,
            disabled: isInstalling,
            onClick: () => {
              void handleActivateExtension(extension);
            },
          });
        } else {
          items.push({
            id: "deactivate",
            label: t("extensions.deactivate"),
            icon: <XCircle className="size-3.5" weight="duotone" />,
            disabled: isInstalling,
            onClick: () => {
              void handleDeactivateExtension(extension);
            },
          });
        }

        const settingKey = getAppearanceSettingKey(extension);
        const currentSelection = settingKey ? settings[settingKey] : undefined;
        const appearanceOptions = extension.appearanceOptions?.length
          ? extension.appearanceOptions
          : extension.selectionId
            ? [{ id: extension.selectionId, name: extension.name }]
            : [];

        if (appearanceOptions.length > 0) {
          if (items.length > 0) {
            items.push({ id: "sep-appearance", label: "", separator: true, onClick: () => {} });
          }

          for (const option of appearanceOptions) {
            const isCurrent = currentSelection === option.id;
            items.push({
              id: `use-${option.id}`,
              label: isCurrent
                ? t("extensions.currentName", { name: option.name })
                : t("extensions.useName", { name: option.name }),
              icon: (
                <Check className="size-3.5 text-primary" weight={isCurrent ? "bold" : "regular"} />
              ),
              disabled: isCurrent || isInstalling,
              onClick: () => {
                void handleUseAppearance(extension, option.id);
              },
            });
          }
        } else if (extension.isEnabled) {
          items.push({
            id: extension.isActive ? "active" : "use",
            label: extension.isActive ? t("extensions.current") : t("extensions.use"),
            icon: <Check className="size-3.5 text-primary" weight="bold" />,
            disabled: extension.isActive || isInstalling,
            onClick: () => {
              void handleUseAppearance(extension);
            },
          });
        }
      } else {
        items.push({
          id: extension.isEnabled ? "deactivate" : "activate",
          label: extension.isEnabled ? t("extensions.deactivate") : t("extensions.activate"),
          icon: extension.isEnabled ? (
            <XCircle className="size-3.5" weight="duotone" />
          ) : (
            <Check className="size-3.5 text-primary" weight="bold" />
          ),
          disabled: isInstalling,
          onClick: () => {
            void handleToggle(extension);
          },
        });
      }
    }

    if ((hasUpdate || hasRuntimeIssue) && extension.isInstalled) {
      items.push({
        id: "update",
        label: hasRuntimeIssue ? t("extensions.reinstall") : t("extensions.update"),
        icon: <RefreshCw className="size-3.5" weight="duotone" />,
        disabled: isInstalling,
        onClick: () => {
          void handleUpdate(extension);
        },
      });
    }

    if (hasLocalOverride) {
      items.push({
        id: "reset",
        label: t("extensions.resetToMarketplaceVersion"),
        icon: <Reset className="size-3.5" weight="duotone" />,
        disabled: isInstalling,
        onClick: () => {
          void handleResetSkillOverride(extension);
        },
      });
    }

    if (items.length > 0) {
      items.push({ id: "sep-primary-action", label: "", separator: true, onClick: () => {} });
    }

    if (!extension.isInstalled) {
      items.push({
        id: "install",
        label: primaryActionLabel,
        icon: <Download className="size-3.5" weight="fill" />,
        disabled: isInstalling || isUnavailableAgent,
        onClick: () => {
          void handleToggle(extension);
        },
      });
    } else if (extension.category === "agent" || extension.category === "skill") {
      items.push({
        id: "toggle",
        label: primaryActionLabel,
        icon: <Trash className="size-3.5" weight="duotone" />,
        disabled: isInstalling,
        className: "text-destructive hover:text-destructive",
        onClick: () => {
          void handleToggle(extension);
        },
      });
    } else if (extension.isMarketplace) {
      items.push({
        id: "uninstall",
        label: t("extensions.uninstall"),
        icon: <Trash className="size-3.5" weight="duotone" />,
        disabled: isInstalling,
        className: "text-destructive hover:text-destructive",
        onClick: () => {
          void handleUninstall(extension);
        },
      });
    }

    return items;
  }, [availableExtensions, extensionContextMenu.data, extensionsWithUpdates, installingAgentIds, t]);

  return (
    <div className="font-sans flex h-full min-h-0 flex-col bg-background">
      <div className="shrink-0 border-border/70 border-b px-5 py-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <Package className="size-5 text-subtle-foreground" weight="duotone" />
              <h1 className="font-semibold text-foreground ui-text-lg">
                {t("extensions.title")}
              </h1>
            </div>
            <div className="mt-1 flex flex-wrap items-center gap-2 ui-text-sm text-subtle-foreground">
              <span>{t("extensions.availableCount", { count: extensions.length })}</span>
              <span>·</span>
              <span>{t("extensions.installedCount", { count: installedCount })}</span>
              {updateCount > 0 ? (
                <>
                  <span>·</span>
                  <span className="text-primary">
                    {t("extensions.updatesCount", { count: updateCount })}
                  </span>
                </>
              ) : null}
            </div>
          </div>

          <div className="flex min-w-65 flex-1 items-center justify-end gap-2 sm:flex-none">
            <SearchField
              ref={searchInputRef}
              autoFocus
              value={searchQuery}
              onChange={setSearchQuery}
              leftIcon={Search}
              placeholder={t("extensions.searchPlaceholder")}
              size="md"
              containerClassName="min-w-0 flex-1 sm:w-80 sm:flex-none"
              className="h-9 bg-surface/45"
            />
            {settings.extensionsActiveTab === "skill" ? (
              <Button variant="default" size="xs" onClick={() => setIsSkillsCommandOpen(true)}>
                <Plus />
                {t("extensions.newSkill")}
              </Button>
            ) : null}
          </div>
        </div>

        <div className="custom-scrollbar-thin mt-4 flex gap-1 overflow-x-auto">
          {FILTER_TABS.map((tab) => {
            const Icon = "icon" in tab ? tab.icon : undefined;
            const active = settings.extensionsActiveTab === tab.id;
            const count = filterCounts[tab.id] ?? 0;

            return (
              <Button
                key={tab.id}
                type="button"
                variant={active ? "default" : "ghost"}
                active={active}
                size="xs"
                className={cn(
                  "group h-8 shrink-0 gap-1.5 px-2.5",
                  active ? "bg-selected text-foreground" : "text-subtle-foreground",
                )}
                onClick={() => void updateSetting("extensionsActiveTab", tab.id as ExtensionTabId)}
              >
                {Icon ? <Icon className="size-3.5" weight={active ? "fill" : "duotone"} /> : null}
                {t(tab.labelKey)}
                <Badge
                  variant={active ? "accent" : "default"}
                  size="compact"
                  className="h-4 min-w-4 px-1"
                >
                  {count}
                </Badge>
              </Button>
            );
          })}
        </div>
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(380px,1fr)_minmax(340px,440px)]">
        <ScrollArea className="min-h-0 border-border/70 border-r" contentClassName="p-5">
          {settings.extensionsActiveTab === "skill" && isLoadingSkills ? (
            <div className="mb-3">
              <Spinner label={t("extensions.loadingSkills")} showLabel compact />
            </div>
          ) : null}

          {settings.extensionsActiveTab === "agent" && isLoadingAgents ? (
            <div className="mb-3">
              <Spinner label={t("extensions.loadingAgents")} showLabel compact />
            </div>
          ) : null}

          {filteredExtensions.length === 0 ? (
            <EmptyState message={t("extensions.noneFound")} />
          ) : (
            <div className="grid grid-cols-1 gap-1 xl:grid-cols-2 xl:gap-x-8 xl:gap-y-2">
              {filteredExtensions.map((extension) => {
                const isInstalling = isExtensionInstalling(extension);
                const hasUpdate = hasExtensionUpdate(extension);
                const hasRuntimeIssue = Boolean(extension.runtimeIssues?.length);

                return (
                  <ExtensionRow
                    key={extension.id}
                    extension={extension}
                    selected={selectedExtension?.id === extension.id}
                    onSelect={() => setSelectedExtensionId(extension.id)}
                    onToggle={() => handleToggle(extension)}
                    onUpdate={() => handleUpdate(extension)}
                    onContextMenu={handleExtensionContextMenu}
                    isInstalling={isInstalling}
                    hasUpdate={hasUpdate}
                    hasRuntimeIssue={hasRuntimeIssue}
                  />
                );
              })}
            </div>
          )}
        </ScrollArea>

        <ScrollArea
          className="hidden min-h-0 bg-surface/25 lg:block"
          contentClassName="p-5"
          render={<aside />}
        >
          {selectedExtension ? (
            <div className="space-y-5">
              <div className="flex items-start gap-3">
                <ExtensionIcon extension={selectedExtension} />
                <div className="min-w-0 flex-1">
                  <h2 className="truncate font-semibold text-foreground ui-text-xl">
                    {selectedExtension.name}
                  </h2>
                  <div className="mt-1 flex flex-wrap items-center gap-1.5 text-subtle-foreground ui-text-sm">
                    {selectedExtension.publisher ? (
                      <span>
                        {t("extensions.byPublisher", { publisher: selectedExtension.publisher })}
                      </span>
                    ) : null}
                    {selectedExtension.version ? <span>v{selectedExtension.version}</span> : null}
                  </div>
                </div>
              </div>

              <div className="flex flex-wrap gap-1.5">
                <Badge variant="default" size="compact">
                  {getCategoryLabel(selectedExtension.category, t)}
                </Badge>
                {selectedExtension.isInstalled ? (
                  <Badge variant="accent" size="compact">
                    {t("extensions.installed")}
                  </Badge>
                ) : null}
                {selectedExtension.isInstalled && !selectedExtension.isEnabled ? (
                  <Badge variant="default" size="compact">
                    {t("extensions.disabled")}
                  </Badge>
                ) : null}
                {hasExtensionUpdate(selectedExtension) ? (
                  <Badge variant="accent" size="compact">
                    {t("extensions.update")}
                  </Badge>
                ) : null}
                {selectedExtension.isActive ? (
                  <Badge variant="accent" size="compact">
                    {t("extensions.active")}
                  </Badge>
                ) : null}
                {selectedExtension.isBundled ? (
                  <Badge variant="accent" size="compact">
                    {t("extensions.builtIn")}
                  </Badge>
                ) : null}
              </div>

              {selectedExtension.description ? (
                <p className="leading-6 text-subtle-foreground ui-text-base">
                  {selectedExtension.description}
                </p>
              ) : null}

              {selectedExtension.runtimeIssues?.length ? (
                <Alert tone="error">
                  <AlertDescription>{selectedExtension.runtimeIssues[0]?.message}</AlertDescription>
                </Alert>
              ) : null}

              {isAppearanceExtension(selectedExtension) &&
              selectedExtension.appearanceOptions?.length ? (
                <div className="border-border/70 border-t pt-4">
                  <div className="mb-2 font-medium text-foreground ui-text-sm">
                    {selectedExtension.category === "theme"
                      ? t("extensions.themes")
                      : t("extensions.iconThemes")}
                  </div>
                  <div className="space-y-2">
                    {selectedExtension.appearanceOptions.map((option) => {
                      const currentSelection =
                        selectedExtension.category === "theme"
                          ? settings.theme
                          : settings.iconTheme;
                      const isCurrent = currentSelection === option.id;

                      return (
                        <div
                          key={option.id}
                          className="flex min-w-0 items-center gap-3 rounded-lg border border-border/65 bg-background px-3 py-2"
                        >
                          <div className="min-w-0 flex-1">
                            <div className="truncate font-medium text-foreground ui-text-sm">
                              {option.name}
                            </div>
                            {option.description ? (
                              <div className="mt-0.5 line-clamp-1 text-subtle-foreground ui-text-sm">
                                {option.description}
                              </div>
                            ) : null}
                          </div>
                          <Button
                            variant={isCurrent ? "default" : "accent"}
                            size="xs"
                            active={isCurrent}
                            disabled={!selectedExtension.isInstalled || isCurrent}
                            onClick={() => void handleUseAppearance(selectedExtension, option.id)}
                          >
                            <Check />
                            {isCurrent
                              ? t("extensions.current")
                              : selectedExtension.isEnabled
                                ? t("extensions.use")
                                : t("extensions.activateAndUse")}
                          </Button>
                        </div>
                      );
                    })}
                  </div>
                </div>
              ) : null}

              <div className="flex flex-wrap gap-2">
                {!selectedExtension.isBundled ? (
                  <Button
                    variant={
                      isAppearanceExtension(selectedExtension) && selectedExtension.isActive
                        ? "default"
                        : isAppearanceExtension(selectedExtension) && selectedExtension.isInstalled
                          ? "accent"
                          : selectedExtension.isInstalled &&
                              (selectedExtension.category === "agent" ||
                                selectedExtension.category === "skill")
                            ? "ghost"
                            : selectedExtension.isInstalled && selectedExtension.isEnabled
                              ? "default"
                              : "accent"
                    }
                    className={
                      selectedExtension.isInstalled &&
                      (selectedExtension.category === "agent" ||
                        selectedExtension.category === "skill")
                        ? "text-subtle-foreground hover:text-destructive"
                        : undefined
                    }
                    onClick={() => void handleToggle(selectedExtension)}
                    disabled={
                      (isAppearanceExtension(selectedExtension) && selectedExtension.isActive) ||
                      isExtensionInstalling(selectedExtension) ||
                      (selectedExtension.category === "agent" &&
                        !selectedExtension.isInstalled &&
                        selectedExtension.canInstall === false)
                    }
                  >
                    {isAppearanceExtension(selectedExtension) && selectedExtension.isInstalled ? (
                      <Check />
                    ) : selectedExtension.isInstalled &&
                      (selectedExtension.category === "agent" ||
                        selectedExtension.category === "skill") ? (
                      <Trash />
                    ) : selectedExtension.isInstalled && selectedExtension.isEnabled ? (
                      <XCircle />
                    ) : selectedExtension.isInstalled ? (
                      <Check />
                    ) : (
                      <Download weight="fill" />
                    )}
                    {getPrimaryActionLabel(selectedExtension, t)}
                  </Button>
                ) : null}
                {selectedExtension.isMarketplace &&
                selectedExtension.isInstalled &&
                selectedExtension.category !== "agent" &&
                selectedExtension.category !== "skill" ? (
                  <Button
                    variant="ghost"
                    className="text-subtle-foreground hover:text-destructive"
                    onClick={() => void handleUninstall(selectedExtension)}
                    disabled={isExtensionInstalling(selectedExtension)}
                  >
                    <Trash />
                    {t("extensions.uninstall")}
                  </Button>
                ) : null}
                {hasExtensionUpdate(selectedExtension) && selectedExtension.isInstalled ? (
                  <Button
                    variant="default"
                    onClick={() => void handleUpdate(selectedExtension)}
                    disabled={isExtensionInstalling(selectedExtension)}
                  >
                    <RefreshCw />
                    {t("extensions.update")}
                  </Button>
                ) : null}
                {canDeactivateAppearanceExtension(selectedExtension) ? (
                  <Button
                    variant="ghost"
                    className="text-subtle-foreground"
                    onClick={() => void handleDeactivateExtension(selectedExtension)}
                  >
                    <XCircle />
                    {t("extensions.deactivate")}
                  </Button>
                ) : null}
                {selectedExtension.skill && hasSkillLocalOverride(selectedExtension.skill) ? (
                  <Button
                    variant="default"
                    onClick={() => void handleResetSkillOverride(selectedExtension)}
                  >
                    <Reset />
                    {t("settings.keyboard.reset")}
                  </Button>
                ) : null}
              </div>

              <div className="border-border/70 border-t pt-4">
                <div className="mb-2 font-medium text-foreground ui-text-sm">
                  {t("extensions.contributions")}
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {(selectedExtension.contributionSummary?.length
                    ? selectedExtension.contributionSummary
                    : selectedExtension.extensions
                      ? selectedExtension.extensions
                      : [getCategoryLabel(selectedExtension.category, t)]
                  ).map((item) => (
                    <Badge key={item} variant="default">
                      {item}
                    </Badge>
                  ))}
                </div>
              </div>
            </div>
          ) : (
            <EmptyState message={t("extensions.noneSelected")} />
          )}
        </ScrollArea>
      </div>

      <SkillsCommand
        isOpen={isSkillsCommandOpen}
        initialView="editor"
        onClose={() => setIsSkillsCommandOpen(false)}
        onSelectSkill={() => setIsSkillsCommandOpen(false)}
      />

      <Dropdown
        isOpen={extensionContextMenu.isOpen}
        point={extensionContextMenu.position}
        items={extensionContextMenuItems}
        onClose={extensionContextMenu.close}
      />
    </div>
  );
};
