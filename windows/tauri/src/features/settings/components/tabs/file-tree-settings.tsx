import { useEffect, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import type { FileTreeSortOrder } from "@/features/settings/types/settings.types";
import NumberInput from "@/ui/number-input";
import Select from "@/ui/select";
import Textarea from "@/ui/textarea";
import Section, { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";
import Switch from "@/ui/switch";
import { useTranslation } from "@/i18n/locale-provider";

export const FileTreeSettings = () => {
  const { t } = useTranslation();
  const settings = useSettingsStore(
    useShallow((state) => ({
      autoRevealActiveFileInFileTree: state.settings.autoRevealActiveFileInFileTree,
      compactFoldersInFileTree: state.settings.compactFoldersInFileTree,
      confirmBeforeFileDelete: state.settings.confirmBeforeFileDelete,
      fileTreeIndentSize: state.settings.fileTreeIndentSize,
      fileTreeSortOrder: state.settings.fileTreeSortOrder,
      hiddenDirectoryPatterns: state.settings.hiddenDirectoryPatterns,
      hiddenFilePatterns: state.settings.hiddenFilePatterns,
      hideRootFolderInFileTree: state.settings.hideRootFolderInFileTree,
      showFileIconsInFileTree: state.settings.showFileIconsInFileTree,
      showGitignoredFilesInFileTree: state.settings.showGitignoredFilesInFileTree,
      showGitStatusInFileTree: state.settings.showGitStatusInFileTree,
      showHiddenFilesInFileTree: state.settings.showHiddenFilesInFileTree,
      showIndentGuidesInFileTree: state.settings.showIndentGuidesInFileTree,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  const [filePatternsInput, setFilePatternsInput] = useState(
    settings.hiddenFilePatterns.join(", "),
  );
  const [directoryPatternsInput, setDirectoryPatternsInput] = useState(
    settings.hiddenDirectoryPatterns.join(", "),
  );

  useEffect(() => {
    setFilePatternsInput(settings.hiddenFilePatterns.join(", "));
  }, [settings.hiddenFilePatterns]);

  useEffect(() => {
    setDirectoryPatternsInput(settings.hiddenDirectoryPatterns.join(", "));
  }, [settings.hiddenDirectoryPatterns]);

  const parsePatterns = (input: string) =>
    input
      .split(",")
      .map((p) => p.trim())
      .filter((p) => p.length > 0);

  const commitFilePatterns = () => {
    updateSetting("hiddenFilePatterns", parsePatterns(filePatternsInput));
  };

  const commitDirectoryPatterns = () => {
    updateSetting("hiddenDirectoryPatterns", parsePatterns(directoryPatternsInput));
  };

  return (
    <SettingsView>
      <Section title={t("settings.files.display")}>
        <SettingRow
          label={t("settings.files.sortOrder")}
          description={t("settings.files.sortOrderDescription")}
          onReset={() => updateSetting("fileTreeSortOrder", getDefaultSetting("fileTreeSortOrder"))}
          canReset={settings.fileTreeSortOrder !== getDefaultSetting("fileTreeSortOrder")}
        >
          <Select
            value={settings.fileTreeSortOrder}
            options={[
              { value: "folders-first", label: t("settings.files.foldersFirst") },
              { value: "name", label: t("settings.files.name") },
            ]}
            onChange={(value) => updateSetting("fileTreeSortOrder", value as FileTreeSortOrder)}
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="sm"
            variant="default"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.indentSize")}
          description={t("settings.files.indentSizeDescription")}
          onReset={() =>
            updateSetting("fileTreeIndentSize", getDefaultSetting("fileTreeIndentSize"))
          }
          canReset={settings.fileTreeIndentSize !== getDefaultSetting("fileTreeIndentSize")}
        >
          <NumberInput
            min="8"
            max="32"
            value={settings.fileTreeIndentSize}
            onChange={(val) => updateSetting("fileTreeIndentSize", val)}
            className={SETTINGS_CONTROL_WIDTHS.numberCompact}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.showFileIcons")}
          description={t("settings.files.showFileIconsDescription")}
          onReset={() =>
            updateSetting("showFileIconsInFileTree", getDefaultSetting("showFileIconsInFileTree"))
          }
          canReset={
            settings.showFileIconsInFileTree !== getDefaultSetting("showFileIconsInFileTree")
          }
        >
          <Switch
            checked={settings.showFileIconsInFileTree}
            onChange={(checked) => updateSetting("showFileIconsInFileTree", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.showIndentGuides")}
          description={t("settings.files.showIndentGuidesDescription")}
          onReset={() =>
            updateSetting(
              "showIndentGuidesInFileTree",
              getDefaultSetting("showIndentGuidesInFileTree"),
            )
          }
          canReset={
            settings.showIndentGuidesInFileTree !== getDefaultSetting("showIndentGuidesInFileTree")
          }
        >
          <Switch
            checked={settings.showIndentGuidesInFileTree}
            onChange={(checked) => updateSetting("showIndentGuidesInFileTree", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.compactFolders")}
          description={t("settings.files.compactFoldersDescription")}
          onReset={() =>
            updateSetting("compactFoldersInFileTree", getDefaultSetting("compactFoldersInFileTree"))
          }
          canReset={
            settings.compactFoldersInFileTree !== getDefaultSetting("compactFoldersInFileTree")
          }
        >
          <Switch
            checked={settings.compactFoldersInFileTree}
            onChange={(checked) => updateSetting("compactFoldersInFileTree", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.hideRootFolder")}
          description={t("settings.files.hideRootFolderDescription")}
          onReset={() =>
            updateSetting("hideRootFolderInFileTree", getDefaultSetting("hideRootFolderInFileTree"))
          }
          canReset={
            settings.hideRootFolderInFileTree !== getDefaultSetting("hideRootFolderInFileTree")
          }
        >
          <Switch
            checked={settings.hideRootFolderInFileTree}
            onChange={(checked) => updateSetting("hideRootFolderInFileTree", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.showHiddenFiles")}
          description={t("settings.files.showHiddenFilesDescription")}
          onReset={() =>
            updateSetting(
              "showHiddenFilesInFileTree",
              getDefaultSetting("showHiddenFilesInFileTree"),
            )
          }
          canReset={
            settings.showHiddenFilesInFileTree !== getDefaultSetting("showHiddenFilesInFileTree")
          }
        >
          <Switch
            checked={settings.showHiddenFilesInFileTree}
            onChange={(checked) => updateSetting("showHiddenFilesInFileTree", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.respectGitignore")}
          description={t("settings.files.respectGitignoreDescription")}
          onReset={() =>
            updateSetting(
              "showGitignoredFilesInFileTree",
              getDefaultSetting("showGitignoredFilesInFileTree"),
            )
          }
          canReset={
            settings.showGitignoredFilesInFileTree !==
            getDefaultSetting("showGitignoredFilesInFileTree")
          }
        >
          <Switch
            checked={!settings.showGitignoredFilesInFileTree}
            onChange={(checked) => updateSetting("showGitignoredFilesInFileTree", !checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.showGitStatus")}
          description={t("settings.files.showGitStatusDescription")}
          onReset={() =>
            updateSetting("showGitStatusInFileTree", getDefaultSetting("showGitStatusInFileTree"))
          }
          canReset={
            settings.showGitStatusInFileTree !== getDefaultSetting("showGitStatusInFileTree")
          }
        >
          <Switch
            checked={settings.showGitStatusInFileTree}
            onChange={(checked) => updateSetting("showGitStatusInFileTree", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.files.behavior")}>
        <SettingRow
          label={t("settings.files.autoReveal")}
          description={t("settings.files.autoRevealDescription")}
          onReset={() =>
            updateSetting(
              "autoRevealActiveFileInFileTree",
              getDefaultSetting("autoRevealActiveFileInFileTree"),
            )
          }
          canReset={
            settings.autoRevealActiveFileInFileTree !==
            getDefaultSetting("autoRevealActiveFileInFileTree")
          }
        >
          <Switch
            checked={settings.autoRevealActiveFileInFileTree}
            onChange={(checked) => updateSetting("autoRevealActiveFileInFileTree", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.confirmBeforeDelete")}
          description={t("settings.files.confirmBeforeDeleteDescription")}
          onReset={() =>
            updateSetting("confirmBeforeFileDelete", getDefaultSetting("confirmBeforeFileDelete"))
          }
          canReset={
            settings.confirmBeforeFileDelete !== getDefaultSetting("confirmBeforeFileDelete")
          }
        >
          <Switch
            checked={settings.confirmBeforeFileDelete}
            onChange={(checked) => updateSetting("confirmBeforeFileDelete", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.files.filters")}>
        <SettingRow
          label={t("settings.files.hiddenFiles")}
          description={t("settings.files.globPatterns")}
          onReset={() =>
            updateSetting("hiddenFilePatterns", getDefaultSetting("hiddenFilePatterns"))
          }
          canReset={
            settings.hiddenFilePatterns.join(",") !==
            getDefaultSetting("hiddenFilePatterns").join(",")
          }
        >
          <Textarea
            value={filePatternsInput}
            onChange={(e) => setFilePatternsInput(e.target.value)}
            onBlur={commitFilePatterns}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                commitFilePatterns();
              }
            }}
            placeholder="*.log, *.tmp, **/*.bak"
            rows={2}
            size="md"
            className="w-48 max-w-full resize-none"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.files.hiddenDirectories")}
          description={t("settings.files.globPatterns")}
          onReset={() =>
            updateSetting("hiddenDirectoryPatterns", getDefaultSetting("hiddenDirectoryPatterns"))
          }
          canReset={
            settings.hiddenDirectoryPatterns.join(",") !==
            getDefaultSetting("hiddenDirectoryPatterns").join(",")
          }
        >
          <Textarea
            value={directoryPatternsInput}
            onChange={(e) => setDirectoryPatternsInput(e.target.value)}
            onBlur={commitDirectoryPatterns}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                commitDirectoryPatterns();
              }
            }}
            placeholder="node_modules, .git, build/"
            rows={2}
            size="md"
            className="w-48 max-w-full resize-none"
          />
        </SettingRow>
      </Section>
    </SettingsView>
  );
};
