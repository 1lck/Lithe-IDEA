import { WarningIcon as AlertTriangle } from "@/ui/icons";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { useTranslation } from "@/i18n/locale-provider";

interface Props {
  onSave: () => void;
  onDiscard: () => void;
  onCancel: () => void;
  fileName: string;
}

const UnsavedChangesDialog = ({ onSave, onDiscard, onCancel, fileName }: Props) => {
  const { t } = useTranslation();

  return (
    <Dialog
      title={t("unsavedChanges.title")}
      icon={AlertTriangle}
      onClose={onCancel}
      size="sm"
      footer={
        <>
          <Button onClick={onCancel} size="xs">
            {t("ui.cancel")}
          </Button>
          <Button onClick={onDiscard} size="xs">
            {t("unsavedChanges.doNotSave")}
          </Button>
          <Button onClick={onSave} variant="accent" size="xs">
            {t("ui.save")}
          </Button>
        </>
      }
    >
      <p className="text-foreground ui-text-sm">
        {t("unsavedChanges.messagePrefix")} <strong>{fileName}</strong>
        {t("unsavedChanges.messageSuffix")}
      </p>
    </Dialog>
  );
};

export default UnsavedChangesDialog;
