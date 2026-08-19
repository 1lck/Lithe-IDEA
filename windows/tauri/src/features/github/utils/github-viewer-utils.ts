import { toast } from "sonner";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { formatCompactRelativeDate } from "@/utils/date";
import { writeClipboardText } from "@/utils/clipboard";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

export function getTimeAgo(dateString: string): string {
  return formatCompactRelativeDate(dateString, { afterWeek: "weeks" });
}

export function getRepositoryDisplayName(repoPath: string): string {
  return repoPath.split(/[\\/]/).filter(Boolean).pop() || repoPath;
}

export async function copyToClipboard(value: string, successMessage: string) {
  try {
    await writeClipboardText(value);
    toast.success(successMessage);
  } catch (error) {
    toast.error(getCurrentTranslator()("github.copyFailed", { error: String(error) }));
  }
}
