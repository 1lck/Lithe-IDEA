import { WarningIcon as AlertTriangle } from "@/ui/icons";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { useTranslation } from "@/i18n/locale-provider";

interface Props {
  serviceTitles: string[];
  stopping: boolean;
  onStopAndClose: () => void;
  onCancel: () => void;
}

const RunningServicesDialog = ({ serviceTitles, stopping, onStopAndClose, onCancel }: Props) => {
  const { t } = useTranslation();

  return (
    <Dialog
      title={t("runningServices.title")}
      icon={AlertTriangle}
      // Once stopping has begun the services are already going away; closing
      // the dialog then would only hide that the window is about to close.
      onClose={stopping ? () => {} : onCancel}
      size="sm"
      footer={
        <>
          <Button onClick={onCancel} size="xs" disabled={stopping}>
            {t("ui.cancel")}
          </Button>
          <Button onClick={onStopAndClose} variant="accent" size="xs" disabled={stopping}>
            {stopping ? t("runningServices.stopping") : t("runningServices.stopAndClose")}
          </Button>
        </>
      }
    >
      <p className="text-foreground ui-text-sm">
        {t("runningServices.message", { count: serviceTitles.length })}
      </p>
      <ul className="mt-2 list-disc pl-5 text-foreground ui-text-sm">
        {serviceTitles.map((title, index) => (
          <li key={`${index}-${title}`}>{title || t("runningServices.untitled")}</li>
        ))}
      </ul>
    </Dialog>
  );
};

export default RunningServicesDialog;
