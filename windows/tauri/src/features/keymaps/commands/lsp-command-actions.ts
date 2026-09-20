import { LspClient } from "@/features/editor/lsp/lsp-client";
import { rebuildJavaIndexForWorkspace } from "@/features/editor/lsp/java-index-recovery";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { createTranslator } from "@/i18n/locale";
import { toast } from "sonner";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

function getActiveLspClient() {
  return LspClient.getInstance();
}

export async function restartAllLanguageServers(): Promise<void> {
  const lspClient = getActiveLspClient();
  const t = getCurrentTranslator();
  if (lspClient.getActiveServerEntries().length === 0) {
    toast.info(t("lsp.noActive"));
    return;
  }

  try {
    await lspClient.restartAllTrackedServers();
    toast.success(t("lsp.languageServersRestarted"));
  } catch (error) {
    toast.error(error instanceof Error ? error.message : t("lsp.restartAllFailed"));
  }
}

export async function stopAllLanguageServers(): Promise<void> {
  const lspClient = getActiveLspClient();
  const t = getCurrentTranslator();
  if (lspClient.getActiveServerEntries().length === 0) {
    toast.info(t("lsp.noActive"));
    return;
  }

  try {
    await lspClient.stopAll();
    toast.success(t("lsp.languageServersStopped"));
  } catch (error) {
    toast.error(error instanceof Error ? error.message : t("lsp.stopAllFailed"));
  }
}

/// Clears the Java language server's on-disk index. The index normally
/// invalidates itself when the workspace structure changes, so this is a
/// recovery path for a corrupted or otherwise stuck index.
export async function rebuildJavaIndex(): Promise<void> {
  const t = getCurrentTranslator();
  const workspacePath = useProjectStore.getState().rootFolderPath;
  if (!workspacePath) {
    toast.info(t("lsp.noProject"));
    return;
  }

  try {
    await rebuildJavaIndexForWorkspace(workspacePath);
    toast.success(t("lsp.javaIndexCleared"));
  } catch (error) {
    toast.error(error instanceof Error ? error.message : t("lsp.javaIndexClearFailed"));
  }
}
