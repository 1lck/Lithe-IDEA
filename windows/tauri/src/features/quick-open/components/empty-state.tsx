import { CommandEmpty } from "@/ui/command";
import { useTranslation } from "@/i18n/locale-provider";
import { Spinner } from "@/ui/spinner";

interface EmptyStateProps {
  isLoadingFiles: boolean;
  isIndexing: boolean;
  debouncedQuery: string;
  query: string;
  filesLength: number;
  hasRootFolder: boolean;
}

export const EmptyState = ({
  isLoadingFiles,
  isIndexing,
  debouncedQuery,
  query,
  filesLength,
  hasRootFolder,
}: EmptyStateProps) => {
  const { t } = useTranslation();
  const getMessage = () => {
    if (!hasRootFolder) {
      return t("quickOpen.openFolder");
    }
    if (debouncedQuery) {
      return t("quickOpen.noMatch");
    }
    if (query) {
      return t("quickOpen.searching");
    }
    if (filesLength === 0) {
      return t("quickOpen.noFilesInProject");
    }
    return t("quickOpen.noFiles");
  };

  return (
    <CommandEmpty>
      <div className="font-sans text-subtle-foreground">
        {isIndexing ? (
          <Spinner label={t("quickOpen.indexing")} showLabel compact />
        ) : isLoadingFiles ? (
          <Spinner label={t("quickOpen.loadingFiles")} showLabel compact />
        ) : (
          getMessage()
        )}
      </div>
    </CommandEmpty>
  );
};
