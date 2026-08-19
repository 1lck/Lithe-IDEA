import { LspClient } from "@/features/editor/lsp/lsp-client";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
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
