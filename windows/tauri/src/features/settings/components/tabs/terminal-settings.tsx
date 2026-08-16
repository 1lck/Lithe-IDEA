import { InfoIcon as Info, PlusIcon as Plus, TrashIcon as Trash2 } from "@/ui/icons";
import { useEffect } from "react";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import { useFontStore } from "@/features/settings/stores/font.store";
import { useTerminalProfilesStore } from "@/features/terminal/stores/profiles.store";
import { useTerminalShellsStore } from "@/features/terminal/stores/shells.store";
import { COMMON_TERMINAL_NERD_FONTS } from "@/features/terminal/utils/terminal-fonts";
import {
  DEFAULT_SHELL_OPTION_VALUE,
  SYSTEM_DEFAULT_PROFILE_ID,
  getAllTerminalProfiles,
} from "@/features/terminal/utils/terminal-profiles";
import { Button } from "@/ui/button";
import { Empty, EmptyDescription } from "@/ui/empty";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import Input from "@/ui/input";
import NumberInput from "@/ui/number-input";
import Section, { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";
import Select from "@/ui/select";
import Switch from "@/ui/switch";
import Textarea from "@/ui/textarea";
import Tooltip from "@/ui/tooltip";
import { useTranslation } from "@/i18n/locale-provider";

export const TerminalSettings = () => {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const monospaceFonts = useFontStore.use.monospaceFonts();
  const { loadMonospaceFonts } = useFontStore.use.actions();
  const profiles = useTerminalProfilesStore.use.profiles();
  const profileActions = useTerminalProfilesStore.use.actions();
  const shells = useTerminalShellsStore.use.shells();

  useEffect(() => {
    loadMonospaceFonts();
    void useTerminalShellsStore.getState().actions.loadShells();
  }, [loadMonospaceFonts]);

  // Combine Nerd Fonts with system monospace fonts
  // Only include Nerd Fonts if they are actually installed on the system
  const installedNerdFonts = COMMON_TERMINAL_NERD_FONTS.filter((nerdFont) =>
    monospaceFonts.some((sysFont) => sysFont.family === nerdFont),
  );

  const fontOptions = [
    ...installedNerdFonts.map((font) => ({
      value: font,
      label: `${font} (${t("settings.terminal.nerdFont")})`,
    })),
    ...monospaceFonts
      .filter((f) => !COMMON_TERMINAL_NERD_FONTS.includes(f.family))
      .map((f) => ({ value: f.family, label: f.family })),
  ];

  // Add custom option if current value is not in list
  if (
    settings.terminalFontFamily &&
    !fontOptions.some((opt) => opt.value === settings.terminalFontFamily)
  ) {
    fontOptions.unshift({
      value: settings.terminalFontFamily,
      label: `${settings.terminalFontFamily} (${t("settings.terminal.custom")})`,
    });
  }

  const shellOptions = [
    { value: DEFAULT_SHELL_OPTION_VALUE, label: t("settings.terminal.systemDefault") },
    ...shells.map((shell) => ({
      value: shell.id,
      label: shell.name,
    })),
  ];
  const selectedDefaultShellId = shellOptions.some(
    (option) => option.value === settings.terminalDefaultShellId,
  )
    ? settings.terminalDefaultShellId || DEFAULT_SHELL_OPTION_VALUE
    : DEFAULT_SHELL_OPTION_VALUE;

  const allProfiles = getAllTerminalProfiles(shells, profiles);
  const profileOptions = allProfiles.map((profile) => ({
    value: profile.id,
    label: profile.name,
  }));
  const selectedDefaultProfileId = profileOptions.some(
    (option) => option.value === settings.terminalDefaultProfileId,
  )
    ? settings.terminalDefaultProfileId || SYSTEM_DEFAULT_PROFILE_ID
    : SYSTEM_DEFAULT_PROFILE_ID;

  useEffect(() => {
    if (
      settings.terminalDefaultShellId &&
      !shells.some((shell) => shell.id === settings.terminalDefaultShellId)
    ) {
      void updateSetting("terminalDefaultShellId", "");
    }
  }, [settings.terminalDefaultShellId, shells, updateSetting]);

  useEffect(() => {
    if (
      settings.terminalDefaultProfileId &&
      !allProfiles.some((profile) => profile.id === settings.terminalDefaultProfileId)
    ) {
      void updateSetting("terminalDefaultProfileId", "");
    }
  }, [allProfiles, settings.terminalDefaultProfileId, updateSetting]);

  return (
    <SettingsView>
      <Section
        title={t("settings.terminal.launch")}
        description={t("settings.terminal.launchDescription")}
      >
        <SettingRow
          label={t("settings.terminal.defaultShell")}
          description={t("settings.terminal.defaultShellDescription")}
          onReset={() =>
            updateSetting("terminalDefaultShellId", getDefaultSetting("terminalDefaultShellId"))
          }
          canReset={settings.terminalDefaultShellId !== getDefaultSetting("terminalDefaultShellId")}
        >
          <Select
            value={selectedDefaultShellId}
            options={shellOptions}
            onChange={(value) =>
              updateSetting(
                "terminalDefaultShellId",
                value === DEFAULT_SHELL_OPTION_VALUE ? "" : value,
              )
            }
            className={SETTINGS_CONTROL_WIDTHS.xwide}
            size="md"
            variant="default"
            searchable
            searchableTrigger="input"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.defaultProfile")}
          description={t("settings.terminal.defaultProfileDescription")}
          onReset={() =>
            updateSetting("terminalDefaultProfileId", getDefaultSetting("terminalDefaultProfileId"))
          }
          canReset={
            settings.terminalDefaultProfileId !== getDefaultSetting("terminalDefaultProfileId")
          }
        >
          <Select
            value={selectedDefaultProfileId}
            options={profileOptions}
            onChange={(value) =>
              updateSetting(
                "terminalDefaultProfileId",
                value === SYSTEM_DEFAULT_PROFILE_ID ? "" : value,
              )
            }
            className={SETTINGS_CONTROL_WIDTHS.xwide}
            size="md"
            variant="default"
            searchable
            searchableTrigger="input"
          />
        </SettingRow>
      </Section>

      <Section
        title={t("settings.terminal.profiles")}
        description={t("settings.terminal.profilesDescription")}
      >
        <div className="space-y-3 px-1">
          <div className="flex items-center justify-between">
            <div className="font-sans ui-text-base text-subtle-foreground">
              {t("settings.terminal.profilesHelp")}
            </div>
            <Button
              variant="default"
              onClick={() =>
                profileActions.addProfile({
                  name: t("settings.terminal.customProfile", { number: profiles.length + 1 }),
                  shell: settings.terminalDefaultShellId || undefined,
                  startupCommands: [],
                })
              }
              size="sm"
            >
              <Plus className="mr-1" />
              {t("settings.terminal.addProfile")}
            </Button>
          </div>

          {profiles.length === 0 ? (
            <Empty className="min-h-24 border border-border/70 bg-surface/50 px-3 py-3">
              <EmptyDescription className="ui-text-base">
                {t("settings.terminal.noCustomProfiles")}
              </EmptyDescription>
            </Empty>
          ) : (
            profiles.map((profile) => (
              <div
                key={profile.id}
                className="space-y-3 rounded-lg border border-border/70 bg-surface/60 p-3"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="font-sans ui-text-base mb-1 text-foreground">
                      {profile.name}
                    </div>
                    <div className="font-sans ui-text-base text-subtle-foreground">
                      {t("settings.terminal.profilePickerDescription")}
                    </div>
                  </div>
                  <Button
                    variant="danger"
                    onClick={() => profileActions.deleteProfile(profile.id)}
                    aria-label={t("settings.terminal.deleteProfile", { profile: profile.name })}
                    size="icon-sm"
                  >
                    <Trash2 />
                  </Button>
                </div>

                <div className="grid gap-3 md:grid-cols-2">
                  <Field>
                    <FieldLabel htmlFor={`terminal-profile-name-${profile.id}`}>
                      {t("settings.terminal.profileName")}
                    </FieldLabel>
                    <Input
                      id={`terminal-profile-name-${profile.id}`}
                      value={profile.name}
                      onChange={(event) =>
                        profileActions.updateProfile(profile.id, {
                          name: event.target.value,
                        })
                      }
                      placeholder={t("settings.terminal.profileNamePlaceholder")}
                      size="md"
                    />
                  </Field>
                  <Field>
                    <FieldLabel htmlFor={`terminal-profile-shell-${profile.id}`}>
                      {t("settings.terminal.profileShell")}
                    </FieldLabel>
                    <Select
                      id={`terminal-profile-shell-${profile.id}`}
                      value={profile.shell || DEFAULT_SHELL_OPTION_VALUE}
                      options={shellOptions}
                      onChange={(value) =>
                        profileActions.updateProfile(profile.id, {
                          shell: value === DEFAULT_SHELL_OPTION_VALUE ? undefined : value,
                        })
                      }
                      className="w-full"
                      size="md"
                      variant="default"
                      searchable
                      searchableTrigger="input"
                    />
                  </Field>
                </div>

                <Field>
                  <FieldLabel htmlFor={`terminal-profile-directory-${profile.id}`}>
                    {t("settings.terminal.startupDirectory")}
                  </FieldLabel>
                  <Input
                    id={`terminal-profile-directory-${profile.id}`}
                    value={profile.startupDirectory || ""}
                    onChange={(event) =>
                      profileActions.updateProfile(profile.id, {
                        startupDirectory: event.target.value || undefined,
                      })
                    }
                    placeholder={t("settings.terminal.startupDirectoryPlaceholder")}
                    size="md"
                  />
                  <FieldDescription>
                    {t("settings.terminal.startupDirectoryDescription")}
                  </FieldDescription>
                </Field>

                <Field>
                  <FieldLabel htmlFor={`terminal-profile-commands-${profile.id}`}>
                    {t("settings.terminal.startupCommands")}
                  </FieldLabel>
                  <Textarea
                    id={`terminal-profile-commands-${profile.id}`}
                    value={(profile.startupCommands || []).join("\n")}
                    onChange={(event) =>
                      profileActions.updateProfile(profile.id, {
                        startupCommands: event.target.value
                          .split("\n")
                          .map((line) => line.trim())
                          .filter(Boolean),
                      })
                    }
                    placeholder={t("settings.terminal.startupCommandsPlaceholder")}
                    rows={3}
                    size="md"
                  />
                  <FieldDescription>{t("settings.terminal.startupCommandsDescription")}</FieldDescription>
                </Field>
              </div>
            ))
          )}
        </div>
      </Section>

      <Section title={t("settings.terminal.typography")}>
        <SettingRow
          label={t("settings.terminal.fontFamily")}
          description={t("settings.terminal.fontFamilyDescription")}
          onReset={() =>
            updateSetting("terminalFontFamily", getDefaultSetting("terminalFontFamily"))
          }
          canReset={settings.terminalFontFamily !== getDefaultSetting("terminalFontFamily")}
        >
          <div className="flex items-center gap-2">
            <Select
              value={settings.terminalFontFamily}
              options={fontOptions}
              onChange={(val) => updateSetting("terminalFontFamily", val)}
              className={SETTINGS_CONTROL_WIDTHS.xwide}
              size="md"
              variant="default"
              searchable
              searchableTrigger="input"
              placeholder={t("settings.terminal.selectFont")}
            />
            <Tooltip content={t("settings.terminal.fontHelp")} side="left">
              <Info className="size-4 cursor-help text-subtle-foreground transition-colors hover:text-foreground" />
            </Tooltip>
          </div>
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.fontSize")}
          description={t("settings.terminal.fontSizeDescription")}
          onReset={() => updateSetting("terminalFontSize", getDefaultSetting("terminalFontSize"))}
          canReset={settings.terminalFontSize !== getDefaultSetting("terminalFontSize")}
        >
          <NumberInput
            min="8"
            max="32"
            value={settings.terminalFontSize}
            onChange={(val) => updateSetting("terminalFontSize", val)}
            className={SETTINGS_CONTROL_WIDTHS.number}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.lineHeight")}
          description={t("settings.terminal.lineHeightDescription")}
          onReset={() =>
            updateSetting("terminalLineHeight", getDefaultSetting("terminalLineHeight"))
          }
          canReset={settings.terminalLineHeight !== getDefaultSetting("terminalLineHeight")}
        >
          <NumberInput
            min="1"
            max="2"
            step={0.1}
            value={settings.terminalLineHeight}
            onChange={(val) => updateSetting("terminalLineHeight", val)}
            className={SETTINGS_CONTROL_WIDTHS.number}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.letterSpacing")}
          description={t("settings.terminal.letterSpacingDescription")}
          onReset={() =>
            updateSetting("terminalLetterSpacing", getDefaultSetting("terminalLetterSpacing"))
          }
          canReset={settings.terminalLetterSpacing !== getDefaultSetting("terminalLetterSpacing")}
        >
          <NumberInput
            min="-5"
            max="5"
            step={0.1}
            value={settings.terminalLetterSpacing}
            onChange={(val) => updateSetting("terminalLetterSpacing", val)}
            className={SETTINGS_CONTROL_WIDTHS.number}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.scrollback")}
          description={t("settings.terminal.scrollbackDescription")}
          onReset={() =>
            updateSetting("terminalScrollback", getDefaultSetting("terminalScrollback"))
          }
          canReset={settings.terminalScrollback !== getDefaultSetting("terminalScrollback")}
        >
          <NumberInput
            min="1000"
            max="100000"
            step={1000}
            value={settings.terminalScrollback}
            onChange={(val) => updateSetting("terminalScrollback", val)}
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.terminal.interaction")}>
        <SettingRow
          label={t("settings.terminal.altClickMovesCursor")}
          description={t("settings.terminal.altClickMovesCursorDescription")}
          onReset={() =>
            updateSetting(
              "terminalAltClickMovesCursor",
              getDefaultSetting("terminalAltClickMovesCursor"),
            )
          }
          canReset={
            settings.terminalAltClickMovesCursor !==
            getDefaultSetting("terminalAltClickMovesCursor")
          }
        >
          <Switch
            checked={settings.terminalAltClickMovesCursor}
            onChange={(checked) => updateSetting("terminalAltClickMovesCursor", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.optionAsMeta")}
          description={t("settings.terminal.optionAsMetaDescription")}
          onReset={() =>
            updateSetting("terminalMacOptionIsMeta", getDefaultSetting("terminalMacOptionIsMeta"))
          }
          canReset={
            settings.terminalMacOptionIsMeta !== getDefaultSetting("terminalMacOptionIsMeta")
          }
        >
          <Switch
            checked={settings.terminalMacOptionIsMeta}
            onChange={(checked) => updateSetting("terminalMacOptionIsMeta", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.rightClickSelectsWord")}
          description={t("settings.terminal.rightClickSelectsWordDescription")}
          onReset={() =>
            updateSetting(
              "terminalRightClickSelectsWord",
              getDefaultSetting("terminalRightClickSelectsWord"),
            )
          }
          canReset={
            settings.terminalRightClickSelectsWord !==
            getDefaultSetting("terminalRightClickSelectsWord")
          }
        >
          <Switch
            checked={settings.terminalRightClickSelectsWord}
            onChange={(checked) => updateSetting("terminalRightClickSelectsWord", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.terminal.cursor")}>
        <SettingRow
          label={t("settings.terminal.cursorStyle")}
          description={t("settings.terminal.cursorStyleDescription")}
          onReset={() =>
            updateSetting("terminalCursorStyle", getDefaultSetting("terminalCursorStyle"))
          }
          canReset={settings.terminalCursorStyle !== getDefaultSetting("terminalCursorStyle")}
        >
          <Select
            value={settings.terminalCursorStyle}
            options={[
              { value: "block", label: t("settings.terminal.block") },
              { value: "underline", label: t("settings.terminal.underline") },
              { value: "bar", label: t("settings.terminal.bar") },
            ]}
            onChange={(val) =>
              updateSetting("terminalCursorStyle", val as "block" | "underline" | "bar")
            }
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
            searchable
            searchableTrigger="input"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.blinkingCursor")}
          description={t("settings.terminal.blinkingCursorDescription")}
          onReset={() =>
            updateSetting("terminalCursorBlink", getDefaultSetting("terminalCursorBlink"))
          }
          canReset={settings.terminalCursorBlink !== getDefaultSetting("terminalCursorBlink")}
        >
          <Switch
            checked={settings.terminalCursorBlink}
            onChange={(val) => updateSetting("terminalCursorBlink", val)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.cursorWidth")}
          description={t("settings.terminal.cursorWidthDescription")}
          onReset={() =>
            updateSetting("terminalCursorWidth", getDefaultSetting("terminalCursorWidth"))
          }
          canReset={settings.terminalCursorWidth !== getDefaultSetting("terminalCursorWidth")}
        >
          <NumberInput
            min="1"
            max="6"
            value={settings.terminalCursorWidth}
            onChange={(val) => updateSetting("terminalCursorWidth", val)}
            className={SETTINGS_CONTROL_WIDTHS.number}
            size="md"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.terminal.inactiveCursorStyle")}
          description={t("settings.terminal.inactiveCursorStyleDescription")}
          onReset={() =>
            updateSetting(
              "terminalCursorInactiveStyle",
              getDefaultSetting("terminalCursorInactiveStyle"),
            )
          }
          canReset={
            settings.terminalCursorInactiveStyle !==
            getDefaultSetting("terminalCursorInactiveStyle")
          }
        >
          <Select
            value={settings.terminalCursorInactiveStyle}
            options={[
              { value: "outline", label: t("settings.terminal.outline") },
              { value: "block", label: t("settings.terminal.block") },
              { value: "bar", label: t("settings.terminal.bar") },
              { value: "underline", label: t("settings.terminal.underline") },
              { value: "none", label: t("settings.terminal.hidden") },
            ]}
            onChange={(value) =>
              updateSetting(
                "terminalCursorInactiveStyle",
                value as typeof settings.terminalCursorInactiveStyle,
              )
            }
            className={SETTINGS_CONTROL_WIDTHS.default}
            size="md"
            variant="default"
          />
        </SettingRow>
      </Section>
    </SettingsView>
  );
};
