import type { SettingsTab } from "@/features/window/stores/ui-state.store";
import type { SettingsCategory } from "../components/settings-panels";
import { matchesSearchQuery } from "@/utils/search-match";
import { createTranslator } from "@/i18n/locale";

const englishLabel = createTranslator("en-US");
const chineseLabel = createTranslator("zh-CN");

export const settingsGroups = [
  { id: "appearance", labelKey: "settings.groups.appearance", categories: ["general", "updates"] },
  { id: "version-control", labelKey: "settings.groups.versionControl", categories: ["git"] },
  { id: "build", labelKey: "settings.groups.build", categories: ["project", "run", "maven"] },
  { id: "languages", labelKey: "settings.groups.languages", categories: ["lsp"] },
  {
    id: "tools",
    labelKey: "settings.groups.tools",
    categories: ["terminal", "ai", "ai-commit", "logs"],
  },
] as const;

export const settingsCategories: Array<{
  id: SettingsCategory;
  labelKey: string;
  terms: string[];
}> = [
  {
    id: "general",
    labelKey: "settings.tabs.general",
    terms: [
      "General",
      "Appearance",
      "Language",
      "Projects",
      "Files",
      "Hidden paths",
      "settings.mac.appearance",
      "settings.mac.colorTheme",
      "settings.mac.appearanceMode",
      "settings.mac.appearanceDescription",
      "settings.mac.language",
      "settings.mac.languageDescription",
      "settings.mac.projects",
      "settings.mac.openProjectsIn",
      "settings.mac.openProjectsDescription",
      "settings.mac.files",
      "settings.mac.autoSave",
      "settings.mac.hiddenPaths",
      "settings.mac.saveLocalChangesWith",
      "settings.mac.gitPolicyDescription",
    ],
  },
  {
    id: "updates",
    labelKey: "settings.tabs.updates",
    terms: [
      "Updates",
      "Application version",
      "settings.mac.softwareUpdate",
      "settings.mac.checkForUpdates",
      "settings.mac.currentVersion",
    ],
  },
  {
    id: "keyboard",
    labelKey: "settings.tabs.keyboard",
    terms: ["Keymap", "Keyboard shortcuts", "Shortcuts", "Actions", "settings.keyboard.search"],
  },
  {
    id: "editor",
    labelKey: "settings.tabs.editor",
    terms: [
      "Editor",
      "Display",
      "Font",
      "Font size",
      "Minimap",
      "Indentation",
      "Tabs",
      "settings.mac.display",
      "settings.editor.fontFamily",
      "settings.editor.fontFamilyDescription",
      "settings.mac.fontSize",
      "settings.editor.fontSizeDescription",
      "settings.editor.fontLigatures",
      "settings.editor.fontLigaturesDescription",
      "settings.mac.showCodeVision",
      "settings.mac.indentation",
      "settings.mac.tabWidth",
      "settings.editor.showMinimap",
      "settings.mac.editorTabs",
      "settings.mac.layout",
    ],
  },
  {
    id: "plugins",
    labelKey: "settings.tabs.plugins",
    terms: [
      "Plugins",
      "Extensions",
      "Installed",
      "Marketplace",
      "Language support",
      "extensions.installed",
      "extensions.marketplace",
      "extensions.themes",
      "extensions.category.language",
    ],
  },
  {
    id: "mcp",
    labelKey: "settings.mcp.title",
    terms: [
      "MCP",
      "Permissions",
      "Agent",
      "settings.mcp.title",
      "settings.mcp.description",
      "settings.mcp.plugins",
      "settings.mcp.allowConfigure",
      "settings.mcp.allowExecute",
      "settings.mcp.copyConfiguration",
    ],
  },
  {
    id: "git",
    labelKey: "settings.tabs.git",
    terms: [
      "Git",
      "Fetch",
      "Tags",
      "Submodules",
      "Prune",
      "Commit identity",
      "user.name",
      "user.email",
      "git.setup.name",
      "git.setup.email",
      "git.execution.title",
      "git.execution.executable",
      "git.execution.helper",
      "git.execution.credentials",
      "git.execution.advanced",
      "git.execution.sources",
      "git.execution.effectiveFetch",
      "git.setup.identity",
      "git.setup.scope",
      "git.fetch.defaults",
      "git.fetch.prune",
      "git.fetch.scope",
      "git.fetch.submodules",
      "git.fetch.tags",
      "git.fetch.credentials",
      "settings.git.integration",
      "settings.git.gitIntegration",
      "settings.git.autoRefresh",
      "settings.git.confirmDiscard",
      "settings.git.view",
      "settings.git.folderChanges",
      "settings.git.untracked",
      "settings.git.stagedFirst",
      "settings.git.openDiff",
      "settings.git.compactBadges",
      "settings.git.collapseEmpty",
      "settings.git.defaultDiff",
      "settings.git.editor",
      "settings.git.inlineBlame",
      "settings.git.gutter",
    ],
  },
  {
    id: "project",
    labelKey: "settings.project.title",
    terms: [
      "Project",
      "Java SDK",
      "JDK",
      "Maven Home",
      "Maven JDK",
      "settings.project.title",
      "run.jdkHome",
      "run.mavenExecutable",
      "run.mavenJdkHome",
      "settings.xml",
      "maven.localRepository",
    ],
  },
  {
    id: "run",
    labelKey: "settings.run.title",
    terms: [
      "Run configurations",
      "Program arguments",
      "VM options",
      "Environment variables",
      "Services",
      "settings.run.title",
      "run.programArguments",
      "run.vmArguments",
      "run.environment",
      "run.workingDirectory",
      "run.nodeExecutable",
      "run.mavenTests",
      "run.jdkHome",
      "run.mavenExecutable",
      "run.mavenJdkHome",
    ],
  },
  {
    id: "maven",
    labelKey: "settings.tabs.maven",
    terms: [
      "Maven",
      "settings.xml",
      "Local repository",
      "maven.settings",
      "maven.settingsDescription",
      "maven.localRepository",
      "maven.mavenExecutable",
      "maven.javaHome",
    ],
  },
  {
    id: "lsp",
    labelKey: "settings.tabs.lsp",
    terms: [
      "LSP",
      "Language server",
      "settings.mac.languageServices",
      "settings.mac.autoCompletion",
      "settings.mac.autoCompletionDescription",
      "settings.mac.parameterHints",
      "settings.mac.semanticHighlighting",
      "settings.mac.detectedServers",
      "settings.mac.detectedServersDescription",
    ],
  },
  {
    id: "terminal",
    labelKey: "settings.tabs.terminal",
    terms: [
      "Terminal",
      "Shell",
      "Default shell",
      "settings.mac.defaultShell",
      "settings.mac.defaultShellDescription",
      "settings.mac.shell",
    ],
  },
  {
    id: "ai",
    labelKey: "settings.tabs.ai",
    terms: [
      "AI Chat",
      "AI Chat & Editing",
      "AI Providers",
      "Model",
      "API key",
      "Endpoint",
      "Ollama",
      "Codex",
      "aiSettings.provider",
      "aiSettings.model",
      "aiSettings.customProvider",
      "aiSettings.apiKeys",
      "aiSettings.baseUrl",
      "aiSettings.apiKey",
      "aiSettings.mode",
      "aiSettings.endpoint",
      "aiSettings.ollamaCloudKey",
      "aiSettings.authentication",
      "aiSettings.acpSession",
      "aiSettings.autocomplete",
      "aiSettings.aiAutocomplete",
      "aiSettings.autocompleteProvider",
      "aiSettings.autocompleteModel",
      "aiSettings.customModel",
      "aiSettings.customBaseUrl",
      "aiSettings.customApiKey",
      "aiSettings.modelList",
      "aiSettings.agentHistory",
    ],
  },
  {
    id: "ai-commit",
    labelKey: "settings.tabs.aiCommit",
    terms: [
      "AI & Commit",
      "Commit message",
      "Pull request",
      "aiCommit.profiles",
      "aiCommit.profile",
      "aiCommit.name",
      "aiCommit.rules",
      "aiCommit.protocol",
      "aiCommit.tokenLimitField",
      "aiCommit.authentication",
      "aiCommit.key",
      "aiCommit.model",
      "aiCommit.endpoint",
      "aiCommit.effort",
      "aiCommit.language",
      "aiCommit.enabled",
      "aiCommit.format",
      "aiCommit.custom",
      "aiCommit.body",
      "aiCommit.subject",
      "aiCommit.diff",
    ],
  },
  {
    id: "logs",
    labelKey: "settings.tabs.logs",
    terms: [
      "Logs",
      "Diagnostics",
      "Bug report",
      "settings.logs.locations",
      "settings.logs.effectivePath",
      "settings.logs.defaultPath",
      "settings.logs.customPath",
      "settings.logs.diagnostics",
      "settings.logs.diagnosticMode",
      "settings.logs.retention",
      "settings.logs.clearCurrent",
      "settings.logs.diagnosticBundle",
      "settings.logs.exportBundle",
    ],
  },
];

export function categoryFromRequestedTab(tab: SettingsTab | null): SettingsCategory {
  if (tab === "language") return "lsp";
  if (tab === "appearance" || tab === "file-explorer" || tab === "advanced" || tab === null)
    return "general";
  return tab;
}

export function settingsGroupForCategory(category: SettingsCategory) {
  return settingsGroups.find((group) => (group.categories as readonly string[]).includes(category));
}

/** Index the current panels' labels in both languages without mounting hidden pages. */
export function filterSettingsCategories(query: string, translate: (key: string) => string) {
  return settingsCategories.filter((category) => {
    const group = settingsGroupForCategory(category.id);
    const terms = [category.labelKey, ...category.terms, ...(group ? [group.labelKey] : [])];
    return matchesSearchQuery(
      query,
      terms.flatMap((term) =>
        term.includes(".") && !term.endsWith(".xml")
          ? [translate(term), englishLabel(term), chineseLabel(term)]
          : [term],
      ),
    );
  });
}
