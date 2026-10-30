import { useEffect, useState } from "react";
import { canUseNativeFileSearch } from "@/features/file-search/utils/file-search-paths";
import { useTranslation } from "@/i18n/locale-provider";
import { Checkbox } from "@/ui/checkbox";
import { InfoIcon } from "@/ui/icons";
import Tooltip from "@/ui/tooltip";
import { SettingRow } from "./settings-section";
import {
  configureWorkspaceIndexing,
  IndexingSettingsError,
  indexingEvent,
  readIndexingSettings,
  writeIndexingSettings,
} from "@/features/file-explorer/stores/workspace-indexing";

export function WorkspaceIndexingSettings({ root }: { root: string | undefined }) {
  const { t } = useTranslation();
  const supported = canUseNativeFileSearch(root);
  const errorKey = (cause: unknown, fallback: string) =>
    cause instanceof IndexingSettingsError ? `indexing.${cause.code}` : fallback;
  const [enabled, setEnabled] = useState(true);
  const [error, setError] = useState("");
  const [failed, setFailed] = useState(false);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    setLoaded(false);
    setFailed(false);
    setError("");
    if (!root) return;
    let disposed = false;
    let generation = 0;
    const read = () => {
      const current = ++generation;
      try {
        setEnabled(readIndexingSettings(root).gitIgnoreEnabled);
        setLoaded(true);
        setError("");
      } catch (cause) {
        setLoaded(false);
        setError(errorKey(cause, "indexing.readFailed"));
        return;
      }
      if (!supported) return;
      void configureWorkspaceIndexing(root)
        .then((status) => {
          if (!disposed && current === generation) setFailed(status.gitIgnoreFailed);
        })
        .catch((cause) => {
          if (!disposed && current === generation)
            setError(errorKey(cause, "indexing.configureFailed"));
        });
    };
    read();
    window.addEventListener(indexingEvent, read);
    return () => {
      disposed = true;
      window.removeEventListener(indexingEvent, read);
    };
  }, [root, supported]);
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
          disabled={!supported || !loaded}
          onCheckedChange={(checked) => {
            if (!root || !supported || !loaded) return;
            try {
              const settings = readIndexingSettings(root);
              writeIndexingSettings(root, { ...settings, gitIgnoreEnabled: checked });
              setEnabled(checked);
              setError("");
            } catch (cause) {
              setError(errorKey(cause, "indexing.writeFailed"));
            }
          }}
        />
      </SettingRow>
      {root && !supported && <p role="status">{t("indexing.remoteUnsupported")}</p>}
      {supported && failed && <p role="alert">{t("indexing.gitFailed")}</p>}
      {error && <p role="alert">{t(error)}</p>}
    </>
  );
}
