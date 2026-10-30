import { useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Checkbox } from "@/ui/checkbox";
import { InfoIcon } from "@/ui/icons";
import Tooltip from "@/ui/tooltip";
import { SettingRow } from "./settings-section";
import {
  configureWorkspaceIndexing,
  indexingEvent,
  readIndexingSettings,
  writeIndexingSettings,
} from "@/features/file-explorer/stores/workspace-indexing";

export function WorkspaceIndexingSettings({ root }: { root: string | undefined }) {
  const { t } = useTranslation();
  const [enabled, setEnabled] = useState(true);
  const [error, setError] = useState("");
  const [failed, setFailed] = useState(false);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    if (!root) return;
    let disposed = false;
    const read = () => {
      try {
        setEnabled(readIndexingSettings(root).gitIgnoreEnabled);
        setLoaded(true);
        setError("");
      } catch (cause) {
        setLoaded(false);
        setError(String(cause));
        return;
      }
      void configureWorkspaceIndexing(root)
        .then((status) => {
          if (!disposed) setFailed(status.gitIgnoreFailed);
        })
        .catch((cause) => {
          if (!disposed) setError(String(cause));
        });
    };
    read();
    window.addEventListener(indexingEvent, read);
    return () => {
      disposed = true;
      window.removeEventListener(indexingEvent, read);
    };
  }, [root]);
  return (
    <>
      <SettingRow
        label={t("indexing.autoGit")}
        labelAccessory={
          <Tooltip content={t("indexing.description")} className="max-w-sm whitespace-normal">
            <InfoIcon className="size-4 cursor-help text-subtle-foreground" />
          </Tooltip>
        }
      >
        <Checkbox
          data-setting-interactive-root="true"
          data-setting-primary-control="true"
          aria-label={t("indexing.autoGit")}
          checked={enabled}
          disabled={!root || !loaded}
          onCheckedChange={(checked) => {
            if (!root || !loaded) return;
            try {
              const settings = readIndexingSettings(root);
              writeIndexingSettings(root, { ...settings, gitIgnoreEnabled: checked });
              setEnabled(checked);
              setError("");
            } catch (cause) {
              setError(String(cause));
            }
          }}
        />
      </SettingRow>
      {failed && <p role="alert">{t("indexing.gitFailed")}</p>}
      {error && <p role="alert">{error}</p>}
    </>
  );
}
