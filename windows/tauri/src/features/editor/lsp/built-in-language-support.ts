import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { getBaseName, normalizePath } from "@/utils/path-helpers";
import {
  cachedDeclarativeLanguageOwner,
  probeDeclarativeLanguageOwner,
} from "./declarative-language-support";

export const JAVA_LANGUAGE_ID = "java";
export const JAVA_PROVIDER_ID = "java";

const VIRTUAL_PATH_PREFIXES = ["remote://", "wsl://", "diff://", "agent-conversation://"];

export function isJavaSourcePath(filePath: string | undefined): boolean {
  if (!filePath || isVirtualEditorPath(filePath)) return false;
  return getBaseName(filePath).toLowerCase().endsWith(".java");
}

export function isBuiltInLspPath(filePath: string | undefined): boolean {
  return isJavaSourcePath(filePath);
}

export function isEditorLspSupported(filePath: string | undefined): boolean {
  if (!filePath || isVirtualEditorPath(filePath)) return false;
  return (
    isBuiltInLspPath(filePath) ||
    extensionRegistry.isLspSupported(filePath) ||
    Boolean(cachedDeclarativeLanguageOwner(filePath))
  );
}

/** Resolve only ownership; native launch validation stays in the LSP resolver. */
export async function resolveEditorLspSupport(filePath: string | undefined): Promise<boolean> {
  if (!filePath || isVirtualEditorPath(filePath)) return false;
  if (isEditorLspSupported(filePath)) return true;
  return Boolean(await probeDeclarativeLanguageOwner(filePath));
}

export function languageIdForEditorFile(filePath: string | undefined): string | undefined {
  if (!filePath || isVirtualEditorPath(filePath)) return undefined;
  if (isJavaSourcePath(filePath)) return JAVA_LANGUAGE_ID;
  return (
    extensionRegistry.getLanguageId(filePath) ||
    cachedDeclarativeLanguageOwner(filePath)?.languageId ||
    undefined
  );
}

function isVirtualEditorPath(filePath: string): boolean {
  const normalized = normalizePath(filePath);
  return VIRTUAL_PATH_PREFIXES.some((prefix) => normalized.startsWith(prefix));
}
