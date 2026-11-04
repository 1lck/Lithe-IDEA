import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { joinPath } from "@/utils/path-helpers";
import type { CodeLensItem } from "@/features/editor/lsp/use-code-lens";
import type { RunActionItem } from "../types/run-action.types";
import type { JavaTestMethod } from "@/features/maven/types/maven.types";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

export function javaTestActionsForFile(
  filePath: string,
  methods: readonly JavaTestMethod[],
  translate: (key: string) => string = getCurrentTranslator(),
): RunActionItem[] {
  if (!/\.java$/i.test(filePath)) return [];
  return [
    {
      id: `maven:test-class:${filePath}`,
      name: translate("maven.runTestClass"),
      description: filePath.split(/[\\/]/).pop() ?? filePath,
      source: "maven",
      sourceLabel: "Maven",
      mavenTest: { filePath },
    },
    ...methods.map((method) => ({
      id: `maven:test-method:${filePath}:${method.name}`,
      name: method.name,
      description: `${filePath.split(/[\\/]/).pop() ?? filePath}:${method.line + 1}`,
      source: "maven" as const,
      sourceLabel: "Maven",
      mavenTest: { filePath, method: method.name },
    })),
  ];
}

export function isRunnableCodeLens(lens: CodeLensItem): boolean {
  return Boolean(lens.command && /\b(run|test|debug|bench|profile)\b/i.test(lens.title));
}

export function codeLensesToRunActions(
  lenses: CodeLensItem[],
  activeFilePath: string,
): RunActionItem[] {
  const fileName = activeFilePath.split(/[\\/]/).pop() || activeFilePath;
  return lenses.filter(isRunnableCodeLens).map((lens, index) => ({
    id: `lsp:${activeFilePath}:${lens.line}:${lens.command}:${index}`,
    name: lens.title,
    description: `${fileName}:${lens.line + 1}`,
    source: "lsp",
    sourceLabel: "LSP",
    codeLens: lens,
  }));
}

export function resolveRunWorkingDirectory(
  workspacePath: string | undefined,
  workingDirectory: string | undefined,
): string | undefined {
  const trimmed = workingDirectory?.trim();
  if (!trimmed || trimmed === ".") return workspacePath;
  if (
    trimmed.startsWith("/") ||
    trimmed.startsWith("remote://") ||
    trimmed.startsWith("wsl://") ||
    /^[A-Za-z]:[\\/]/.test(trimmed)
  ) {
    return trimmed;
  }
  return workspacePath ? joinPath(workspacePath, trimmed) : trimmed;
}
