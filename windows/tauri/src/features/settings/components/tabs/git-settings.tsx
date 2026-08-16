import { useShallow } from "zustand/react/shallow";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import Section, { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";
import Select from "@/ui/select";
import Switch from "@/ui/switch";

export const GitSettings = () => {
  const { t } = useTranslation();
  const settings = useSettingsStore(
    useShallow((state) => ({
      autoRefreshGitStatus: state.settings.autoRefreshGitStatus,
      collapseEmptyGitSections: state.settings.collapseEmptyGitSections,
      compactGitStatusBadges: state.settings.compactGitStatusBadges,
      confirmBeforeDiscard: state.settings.confirmBeforeDiscard,
      coreFeatures: state.settings.coreFeatures,
      enableInlineGitBlame: state.settings.enableInlineGitBlame,
      gitChangesFolderView: state.settings.gitChangesFolderView,
      gitDefaultDiffView: state.settings.gitDefaultDiffView,
      openDiffOnClick: state.settings.openDiffOnClick,
      rememberLastGitPanelMode: state.settings.rememberLastGitPanelMode,
      showStagedFirst: state.settings.showStagedFirst,
      showUntrackedFiles: state.settings.showUntrackedFiles,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  const handleGitFeatureToggle = (enabled: boolean) => {
    updateSetting("coreFeatures", {
      ...settings.coreFeatures,
      git: enabled,
    });
  };

  return (
    <SettingsView>
      <Section title={t("settings.git.integration")}>
        <SettingRow
          label={t("settings.git.gitIntegration")}
          description={t("settings.git.gitIntegrationDescription")}
          onReset={() => updateSetting("coreFeatures", getDefaultSetting("coreFeatures"))}
          canReset={settings.coreFeatures.git !== getDefaultSetting("coreFeatures").git}
        >
          <Switch checked={settings.coreFeatures.git} onChange={handleGitFeatureToggle} size="sm" />
        </SettingRow>

        <SettingRow
          label={t("settings.git.autoRefresh")}
          description={t("settings.git.autoRefreshDescription")}
          onReset={() =>
            updateSetting("autoRefreshGitStatus", getDefaultSetting("autoRefreshGitStatus"))
          }
          canReset={settings.autoRefreshGitStatus !== getDefaultSetting("autoRefreshGitStatus")}
        >
          <Switch
            checked={settings.autoRefreshGitStatus}
            onChange={(checked) => updateSetting("autoRefreshGitStatus", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.confirmDiscard")}
          description={t("settings.git.confirmDiscardDescription")}
          onReset={() =>
            updateSetting("confirmBeforeDiscard", getDefaultSetting("confirmBeforeDiscard"))
          }
          canReset={settings.confirmBeforeDiscard !== getDefaultSetting("confirmBeforeDiscard")}
        >
          <Switch
            checked={settings.confirmBeforeDiscard}
            onChange={(checked) => updateSetting("confirmBeforeDiscard", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.git.view")}>
        <SettingRow
          label={t("settings.git.folderChanges")}
          description={t("settings.git.folderChangesDescription")}
          onReset={() =>
            updateSetting("gitChangesFolderView", getDefaultSetting("gitChangesFolderView"))
          }
          canReset={settings.gitChangesFolderView !== getDefaultSetting("gitChangesFolderView")}
        >
          <Switch
            checked={settings.gitChangesFolderView}
            onChange={(checked) => updateSetting("gitChangesFolderView", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.untracked")}
          description={t("settings.git.untrackedDescription")}
          onReset={() =>
            updateSetting("showUntrackedFiles", getDefaultSetting("showUntrackedFiles"))
          }
          canReset={settings.showUntrackedFiles !== getDefaultSetting("showUntrackedFiles")}
        >
          <Switch
            checked={settings.showUntrackedFiles}
            onChange={(checked) => updateSetting("showUntrackedFiles", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.stagedFirst")}
          description={t("settings.git.stagedFirstDescription")}
          onReset={() => updateSetting("showStagedFirst", getDefaultSetting("showStagedFirst"))}
          canReset={settings.showStagedFirst !== getDefaultSetting("showStagedFirst")}
        >
          <Switch
            checked={settings.showStagedFirst}
            onChange={(checked) => updateSetting("showStagedFirst", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.openDiff")}
          description={t("settings.git.openDiffDescription")}
          onReset={() => updateSetting("openDiffOnClick", getDefaultSetting("openDiffOnClick"))}
          canReset={settings.openDiffOnClick !== getDefaultSetting("openDiffOnClick")}
        >
          <Switch
            checked={settings.openDiffOnClick}
            onChange={(checked) => updateSetting("openDiffOnClick", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.compactBadges")}
          description={t("settings.git.compactBadgesDescription")}
          onReset={() =>
            updateSetting("compactGitStatusBadges", getDefaultSetting("compactGitStatusBadges"))
          }
          canReset={settings.compactGitStatusBadges !== getDefaultSetting("compactGitStatusBadges")}
        >
          <Switch
            checked={settings.compactGitStatusBadges}
            onChange={(checked) => updateSetting("compactGitStatusBadges", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.collapseEmpty")}
          description={t("settings.git.collapseEmptyDescription")}
          onReset={() =>
            updateSetting("collapseEmptyGitSections", getDefaultSetting("collapseEmptyGitSections"))
          }
          canReset={
            settings.collapseEmptyGitSections !== getDefaultSetting("collapseEmptyGitSections")
          }
        >
          <Switch
            checked={settings.collapseEmptyGitSections}
            onChange={(checked) => updateSetting("collapseEmptyGitSections", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.rememberPanel")}
          description={t("settings.git.rememberPanelDescription")}
          onReset={() =>
            updateSetting("rememberLastGitPanelMode", getDefaultSetting("rememberLastGitPanelMode"))
          }
          canReset={
            settings.rememberLastGitPanelMode !== getDefaultSetting("rememberLastGitPanelMode")
          }
        >
          <Switch
            checked={settings.rememberLastGitPanelMode}
            onChange={(checked) => updateSetting("rememberLastGitPanelMode", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.git.defaultDiff")}
          description={t("settings.git.defaultDiffDescription")}
          onReset={() =>
            updateSetting("gitDefaultDiffView", getDefaultSetting("gitDefaultDiffView"))
          }
          canReset={settings.gitDefaultDiffView !== getDefaultSetting("gitDefaultDiffView")}
        >
          <Select
            value={settings.gitDefaultDiffView}
            options={[
              { value: "unified", label: t("settings.git.unified") },
              { value: "split", label: t("settings.git.split") },
            ]}
            onChange={(value) => updateSetting("gitDefaultDiffView", value as "unified" | "split")}
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
            searchable
            searchableTrigger="input"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.git.editor")}>
        <SettingRow
          label={t("settings.git.inlineBlame")}
          description={t("settings.git.inlineBlameDescription")}
          onReset={() =>
            updateSetting("enableInlineGitBlame", getDefaultSetting("enableInlineGitBlame"))
          }
          canReset={settings.enableInlineGitBlame !== getDefaultSetting("enableInlineGitBlame")}
        >
          <Switch
            checked={settings.enableInlineGitBlame}
            onChange={(checked) => updateSetting("enableInlineGitBlame", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>
    </SettingsView>
  );
};
