import { CommandHeaderBadge } from "@/ui/command";
import { useTranslation } from "@/i18n/locale-provider";

interface FileCountBadgeProps {
  totalFiles: number;
  resultCount: number;
  hasQuery: boolean;
  isLoading: boolean;
}

export const FileCountBadge = ({
  totalFiles,
  resultCount,
  hasQuery,
  isLoading,
}: FileCountBadgeProps) => {
  const { t } = useTranslation();
  if (isLoading || totalFiles === 0) return null;

  const displayText = hasQuery
    ? `${resultCount} / ${totalFiles}`
    : totalFiles === 1
      ? t("quickOpen.fileCountOne", { count: totalFiles })
      : t("quickOpen.filesCount", { count: totalFiles });

  return <CommandHeaderBadge>{displayText}</CommandHeaderBadge>;
};
