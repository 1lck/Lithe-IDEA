import { useEffect, useState } from "react";
import { executeCore } from "@/core/lithe-core-client";
import { useSettingsStore } from "../stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { frontendTrace } from "@/utils/frontend-trace";
import NumberInput from "@/ui/number-input";
import { Button } from "@/ui/button";
import { SettingRow } from "./settings-section";

interface TimeoutPolicy {
  minutes: number;
  milliseconds: number;
  minimumMinutes: number;
  maximumMinutes: number;
}

async function resolveTimeout(minutes?: number): Promise<TimeoutPolicy> {
  const response = await executeCore<TimeoutPolicy>({
    id: crypto.randomUUID(),
    command: "lsp.readinessTimeoutPolicy",
    payload: { minutes },
  });
  if (!response.ok) throw new Error(response.error.code);
  return response.data;
}

/** The preference belongs to Lithe, not to Maven or JDT LS configuration files. */
export function JavaImportTimeoutSettings() {
  const { t } = useTranslation();
  const saved = useSettingsStore((state) => state.settings.javaImportTimeoutMinutes);
  const update = useSettingsStore((state) => state.actions.updateSetting);
  const [policy, setPolicy] = useState<TimeoutPolicy>();
  const [draft, setDraft] = useState<number>();
  const [error, setError] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let disposed = false;
    setError(false);
    void resolveTimeout(saved)
      .then((value) => {
        if (!disposed) {
          setPolicy(value);
          setDraft(value.minutes);
        }
      })
      .catch((cause) => {
        frontendTrace("warn", "lsp.runtime", "Could not resolve Java import timeout", {
          error: String(cause),
        });
        if (!disposed) setError(true);
      });
    return () => {
      disposed = true;
    };
  }, [saved]);
  const save = async (minutes?: number) => {
    setBusy(true);
    setError(false);
    try {
      const value = await resolveTimeout(minutes);
      await update("javaImportTimeoutMinutes", minutes);
      setPolicy(value);
      setDraft(value.minutes);
    } catch (cause) {
      frontendTrace("warn", "lsp.runtime", "Could not save Java import timeout", {
        error: String(cause),
      });
      setError(true);
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <SettingRow label={t("javaImport.timeout")} description={t("javaImport.timeoutInfo")}>
        <NumberInput
          aria-label={t("javaImport.timeout")}
          value={draft ?? ""}
          min={policy?.minimumMinutes}
          max={policy?.maximumMinutes}
          step={1}
          disabled={!policy || busy}
          onChange={setDraft}
          className="w-24"
        />
        <Button
          disabled={!policy || busy || draft === policy.minutes}
          onClick={() => void save(draft)}
        >
          {t("javaImport.timeoutSave")}
        </Button>
        <Button disabled={busy || (saved === undefined && !error)} onClick={() => void save()}>
          {t("javaImport.timeoutReset")}
        </Button>
      </SettingRow>
      {error && <p role="alert">{t("javaImport.timeoutError")}</p>}
    </>
  );
}
