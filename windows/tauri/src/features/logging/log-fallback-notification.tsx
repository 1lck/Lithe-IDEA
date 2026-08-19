import { useEffect } from "react";
import type { LogSettingsSnapshot } from "./log-api";
import { initializeFrontendLogging } from "./frontend-log-runtime";
import { useToast } from "@/features/layout/contexts/toast-context";
import { useTranslation } from "@/i18n/locale-provider";

export function LogFallbackNotification() {
  const { showToast } = useToast();
  const { t } = useTranslation();

  useEffect(() => {
    let lastSignature = "";
    const showFallback = (settings: LogSettingsSnapshot | null) => {
      if (!settings?.fallback_reason) return;
      const signature = `${settings.fallback_reason}:${settings.effective_path}`;
      if (signature === lastSignature) return;
      lastSignature = signature;
      showToast({
        key: "log-directory-fallback",
        type: "warning",
        message:
          settings.fallback_reason === "logging_unavailable"
            ? t("settings.logs.unavailableNotification")
            : t("settings.logs.fallbackNotification", {
                path: settings.configured_path ?? settings.default_path,
              }),
      });
    };
    const handleRuntimeFallback = (event: Event) => {
      showFallback((event as CustomEvent<LogSettingsSnapshot>).detail);
    };
    window.addEventListener("lithe-log-runtime-fallback", handleRuntimeFallback);
    void initializeFrontendLogging().then(showFallback).catch(() => {});
    return () => {
      window.removeEventListener("lithe-log-runtime-fallback", handleRuntimeFallback);
    };
  }, [showToast, t]);

  return null;
}
