import { toast } from "sonner";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { JavaProjectImportOnOpen } from "@/features/settings/types/settings.types";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { createTranslator } from "@/i18n/locale";
import { getFolderName } from "@/utils/path-helpers";
import { JAVA_LANGUAGE_ID } from "./built-in-language-support";
import { languageServerInteractiveToastOptions } from "./language-server-feedback-options";

export type JavaImportOnOpenDecision = "start" | "ask" | "skip";

/**
 * What opening a Java project does with the language-server import.
 *
 * Reactivating a project tab runs the same path, so an import that is already
 * running or done simply continues. "Manual" only skips the import on open:
 * opening a Java file, running code or reloading Maven still imports, because
 * each of those needs the project model.
 */
export function javaImportOnOpenDecision(
  policy: JavaProjectImportOnOpen,
  alreadyImporting: boolean,
): JavaImportOnOpenDecision {
  if (alreadyImporting || policy === "automatic") return "start";
  return policy === "ask" ? "ask" : "skip";
}

/**
 * Offers the import with a way to adjust Maven first. The toast shares its id
 * with the language-server feedback for this project, so starting the import
 * replaces it with the preparing state.
 */
export function askToImportJavaProject(workspacePath: string, startImport: () => void): void {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  toast.info(t("javaImport.askOnOpen", { project: getFolderName(workspacePath) }), {
    ...languageServerInteractiveToastOptions(workspacePath, JAVA_LANGUAGE_ID),
    duration: Number.POSITIVE_INFINITY,
    action: { label: t("javaImport.import"), onClick: startImport },
    cancel: {
      label: t("javaImport.configureFirst"),
      onClick: () => useUIState.getState().openSettingsDialog("maven"),
    },
  });
}
