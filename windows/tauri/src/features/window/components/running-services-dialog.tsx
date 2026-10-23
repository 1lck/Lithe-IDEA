import { WarningIcon as AlertTriangle } from "@/ui/icons";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { useTranslation } from "@/i18n/locale-provider";
import type { RunServicesPrompt } from "@/features/window/services/run-services-exit";

interface Props {
  prompt: RunServicesPrompt;
  onStop: () => void;
  onCancel: () => void;
}

const MESSAGE_KEYS = {
  closeWindow: "runningServices.message",
  quit: "runningServices.quitMessage",
  update: "runningServices.updateMessage",
} as const;

const STOP_KEYS = {
  closeWindow: "runningServices.stopAndClose",
  quit: "runningServices.stopAndQuit",
  update: "runningServices.stopAndUpdate",
} as const;

const RunningServicesDialog = ({ prompt, onStop, onCancel }: Props) => {
  const { t } = useTranslation();
  const { purpose, titles, stopping, error } = prompt;

  return (
    <Dialog
      title={t("runningServices.title")}
      icon={AlertTriangle}
      // Once stopping has begun the services are already going away; closing
      // the dialog then would only hide whether they ended.
      onClose={stopping ? () => {} : onCancel}
      size="sm"
      footer={
        <>
          <Button onClick={onCancel} size="xs" disabled={stopping}>
            {t("ui.cancel")}
          </Button>
          <Button onClick={onStop} variant="accent" size="xs" disabled={stopping}>
            {stopping ? t("runningServices.stopping") : t(STOP_KEYS[purpose])}
          </Button>
        </>
      }
    >
      <p className="text-foreground ui-text-sm">
        {t(MESSAGE_KEYS[purpose], { count: titles.length })}
      </p>
      <ul className="mt-2 list-disc pl-5 text-foreground ui-text-sm">
        {titles.map((title, index) => (
          <li key={`${index}-${title}`}>{title || t("runningServices.untitled")}</li>
        ))}
      </ul>
      {error && (
        <p role="alert" className="mt-2 text-destructive ui-text-sm">
          {t("runningServices.stopFailed", { error })}
        </p>
      )}
    </Dialog>
  );
};

export default RunningServicesDialog;
