import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { toast } from "sonner";
import { getLanguageDisplayName } from "../utils/language-id";

export function languageDisplayName(languageId: string | undefined): string {
  return languageId ? getLanguageDisplayName(languageId) : "Language";
}

function serverKey(workspacePath: string, languageId: string): string {
  return `${workspacePath.replace(/\\/g, "/").toLowerCase()}:${languageId}`;
}

export function showLanguageServerReady(workspacePath: string, languageId: string): void {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  toast.success(t("lsp.readyNamed", { name: languageDisplayName(languageId) }), {
    id: serverKey(workspacePath, languageId),
    duration: 3500,
  });
}

export function showLanguageServerPreparing(workspacePath: string, languageId: string): void {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  toast.loading(t("lsp.preparingNamed", { name: languageDisplayName(languageId) }), {
    id: serverKey(workspacePath, languageId),
    duration: Number.POSITIVE_INFINITY,
  });
}

export type LanguageServerFailureFeedback =
  | { kind: "unavailable" }
  | { kind: "failed"; detail?: string }
  | { kind: "timedOut"; detail?: string };

export function showLanguageServerFailure(
  workspacePath: string,
  languageId: string,
  failure: LanguageServerFailureFeedback,
  retry: () => void,
): void {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  const name = languageDisplayName(languageId);
  const message = t(
    failure.kind === "timedOut"
      ? "lsp.timedOutNamed"
      : failure.kind === "unavailable"
        ? "lsp.unavailableNamed"
        : "lsp.failedNamed",
    { name },
  );
  const detail = "detail" in failure ? failure.detail?.trim() : undefined;
  toast.error(
    detail ? `${message} ${detail}` : message,
    {
      id: serverKey(workspacePath, languageId),
      duration: 10_000,
      action: { label: t("lsp.retry"), onClick: retry },
    },
  );
}

export function clearLanguageServerReadyFeedback(workspacePath: string, languageId?: string): void {
  if (languageId) toast.dismiss(serverKey(workspacePath, languageId));
}
