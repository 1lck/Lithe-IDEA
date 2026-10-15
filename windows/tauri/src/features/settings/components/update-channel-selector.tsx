import { useState } from "react";
import { useUpdater } from "../hooks/use-updater";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import AppDialog from "@/ui/dialog";
import SettingsSelect from "@/ui/settings-select";
import { SettingRow } from "./settings-section";

export function UpdateChannelSelector() {
  const { t } = useTranslation();
  const { channel, channelPreferenceError, operationBusy, checking, downloading, installing, setChannel } = useUpdater(false);
  const [confirming, setConfirming] = useState(false);
  const busy = operationBusy || checking || downloading || installing;
  return (
    <>
      <SettingRow label={t("update.channel")}>
        <SettingsSelect
          aria-label={t("update.channel")}
          value={channel}
          disabled={busy}
          options={[
            { value: "stable", label: t("update.channelStable") },
            { value: "autobuild", label: "AutoBuild" },
          ]}
          onChange={(value) => {
            if (value === "autobuild" && channel !== "autobuild") setConfirming(true);
            else setChannel(value);
          }}
        />
      </SettingRow>
      <p className="ui-text-sm text-subtle-foreground">{t("update.autobuildWarning")}</p>
      {channelPreferenceError ? <p role="alert">{t("update.channelSaveFailed")}</p> : null}
      {confirming ? (
        <AppDialog
          title={t("update.confirmAutobuild")}
          onClose={() => setConfirming(false)}
          size="sm"
          footer={<>
            <Button variant="ghost" onClick={() => setConfirming(false)}>{t("ui.cancel")}</Button>
            <Button disabled={busy} onClick={() => {
              if (setChannel("autobuild", true)) setConfirming(false);
            }}>{t("update.useAutobuild")}</Button>
          </>}
        >
          <p>{t("update.autobuildWarning")}</p>
          <p className="mt-3">{t("update.manualDownloadExplanation")}</p>
        </AppDialog>
      ) : null}
    </>
  );
}
