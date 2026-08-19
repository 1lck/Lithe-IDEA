import { FileIcon } from "@/ui/icons";
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";

export function BinaryDiffViewer({ fileName }: { fileName: string }) {
  const { t } = useTranslation();

  return (
    <Empty className="min-h-40 rounded-none">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <FileIcon />
        </EmptyMedia>
        <EmptyTitle>{t("git.binaryFileChanged")}</EmptyTitle>
        <EmptyDescription>
          {t("git.binaryDiffDescription", { name: fileName })}
        </EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}
