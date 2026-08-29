import { save } from "@tauri-apps/plugin-dialog";
import { writeTextFile } from "@tauri-apps/plugin-fs";
import { useToast } from "@/features/layout/contexts/toast-context";
import { createCoreFeaturesList } from "@/features/settings/config/features";
import { TypedConfirmAction } from "@/features/settings/components/typed-confirm-action";
import { createSettingsExportPayload } from "@/features/settings/lib/settings-import-export";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import type { CoreFeature } from "@/features/settings/types/feature.types";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import Switch from "@/ui/switch";
import Section, { SettingsView, SettingRow } from "../settings-section";
import { useTranslation } from "@/i18n/locale-provider";

const UNSUPPORTED_FEATURE_IDS = new Set([
  "github",
  "remote",
  "debugger",
  "aiChat",
  "webViewer",
]);

export const AdvancedSettings = () => {
  const { t } = useTranslation();
  const coreFeatures = useSettingsStore((state) => state.settings.coreFeatures);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const resetToDefaults = useSettingsStore((state) => state.actions.resetToDefaults);
  const { showToast } = useToast();

  const handleResetSettings = () => {
    resetToDefaults();
    showToast({ message: t("settings.advanced.settingsReset"), type: "success" });
  };
  const defaultCoreFeatures = getDefaultSetting("coreFeatures");
  const coreFeaturesList = createCoreFeaturesList(coreFeatures).filter(
    (feature: CoreFeature) => feature.id !== "git" && !UNSUPPORTED_FEATURE_IDS.has(feature.id),
  );

  const handleCoreFeatureToggle = (featureId: string, enabled: boolean) => {
    updateSetting("coreFeatures", {
      ...coreFeatures,
      [featureId]: enabled,
    });
  };

  const handleResetFeature = (featureId: string) => {
    updateSetting("coreFeatures", {
      ...coreFeatures,
      [featureId]: defaultCoreFeatures[featureId as keyof typeof defaultCoreFeatures],
    });
  };

  const handleExportSettings = async () => {
    try {
      const targetPath = await save({
        defaultPath: "lithe-settings.json",
        filters: [
          { name: t("settings.common.json"), extensions: ["json"] },
          { name: t("settings.common.allFiles"), extensions: ["*"] },
        ],
      });

      if (!targetPath) {
        return;
      }

      const payload = createSettingsExportPayload(useSettingsStore.getState().settings);
      await writeTextFile(targetPath, JSON.stringify(payload, null, 2));
      showToast({ message: t("settings.advanced.settingsExported"), type: "success" });
    } catch (error) {
      console.error("Failed to export settings:", error);
      const message =
        error instanceof Error
          ? error.message
          : typeof error === "string"
            ? error
            : JSON.stringify(error);

      showToast({
        message: t("settings.advanced.exportFailed", { error: message }),
        type: "error",
      });
    }
  };

  const handleImportSettings = () => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "application/json";
    input.onchange = async (event: Event) => {
      const file = (event.target as HTMLInputElement).files?.[0];

      if (!file) {
        return;
      }

      try {
        const text = await file.text();
        const imported = useSettingsStore.getState().actions.updateSettingsFromJSON(text);

        if (!imported) {
          showToast({ message: t("settings.advanced.invalidFile"), type: "error" });
          return;
        }

        showToast({ message: t("settings.advanced.settingsImported"), type: "success" });
      } catch (error) {
        console.error("Failed to import settings:", error);
        showToast({
          message: t("settings.advanced.importFailed", { error: String(error) }),
          type: "error",
        });
      }
    };
    input.click();
  };

  return (
    <SettingsView>
      <Section
        title={t("settings.advanced.features")}
        description={t("settings.advanced.featuresDescription")}
      >
        {coreFeaturesList.map((feature: CoreFeature) => (
          <SettingRow
            key={feature.id}
            label={t(`settings.advanced.feature.${feature.id}.name`)}
            labelAccessory={
              feature.status === "experimental" ? (
                <Badge variant="accent" size="compact" className="uppercase">
                  {t("settings.advanced.experimental")}
                </Badge>
              ) : undefined
            }
            description={t(`settings.advanced.feature.${feature.id}.description`)}
            onReset={() => handleResetFeature(feature.id)}
            canReset={
              feature.enabled !==
              defaultCoreFeatures[feature.id as keyof typeof defaultCoreFeatures]
            }
          >
            <Switch
              checked={feature.enabled}
              onChange={(checked) => handleCoreFeatureToggle(feature.id, checked)}
              size="sm"
            />
          </SettingRow>
        ))}
      </Section>
      <Section title={t("settings.advanced.data")}>
        <SettingRow
          label={t("settings.advanced.exportSettings")}
          description={t("settings.advanced.exportSettingsDescription")}
        >
          <Button variant="default" onClick={() => void handleExportSettings()} size="sm">
            {t("settings.keyboard.export")}
          </Button>
        </SettingRow>
        <SettingRow
          label={t("settings.advanced.importSettings")}
          description={t("settings.advanced.importSettingsDescription")}
        >
          <Button variant="default" onClick={handleImportSettings} size="sm">
            {t("settings.keyboard.import")}
          </Button>
        </SettingRow>
        <SettingRow
          label={t("settings.advanced.resetSettings")}
          description={t("settings.advanced.resetSettingsDescription")}
        >
          <TypedConfirmAction actionLabel={t("settings.advanced.reset")} onConfirm={handleResetSettings} />
        </SettingRow>
      </Section>
    </SettingsView>
  );
};
