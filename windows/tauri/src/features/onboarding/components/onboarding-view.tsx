import { FolderOpenIcon as FolderOpen } from "@/ui/icons";
import { useEffect, useState, type ReactNode } from "react";
import { useShallow } from "zustand/react/shallow";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { IdeSettingsImportDialog } from "@/features/file-system/components/ide-settings-import-dialog";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import {
  type KeybindingPreset,
  keybindingPresetOptions,
} from "@/features/keymaps/defaults/keybinding-presets";
import { markOnboardingCompleted } from "@/features/onboarding/lib/onboarding-state";
import type { OnboardingContext } from "@/features/onboarding/lib/onboarding-state";
import { buildOnboardingViewModel } from "@/features/onboarding/lib/onboarding-view-model";
import { useOnboardingStore } from "@/features/onboarding/stores/onboarding.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { formatReleaseDate } from "@/features/settings/lib/whats-new";
import { useWhatsNewStore } from "@/features/settings/stores/whats-new.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Card } from "@/ui/card";
import { ScrollArea } from "@/ui/scroll-area";
import Select from "@/ui/select";
import Switch from "@/ui/switch";
import { ReleaseNotesContent } from "./release-notes-content";

interface OnboardingViewProps {
  bufferId: string;
  context: OnboardingContext;
}

function SettingRow({
  title,
  description,
  children,
}: {
  title: string;
  description?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-5 border-border/70 border-b px-5 py-4 last:border-b-0">
      <div className="min-w-0">
        <div className="font-sans ui-text-sm font-medium text-foreground">{title}</div>
        {description ? (
          <p className="font-sans ui-text-sm mt-1 max-w-140 text-muted-foreground">{description}</p>
        ) : null}
      </div>
      <div className="shrink-0">{children}</div>
    </div>
  );
}

export default function OnboardingView({ bufferId, context }: OnboardingViewProps) {
  const { t } = useTranslation();
  const settings = useSettingsStore(
    useShallow((state) => ({
      keybindingPreset: state.settings.keybindingPreset,
      openFoldersInNewWindow: state.settings.openFoldersInNewWindow,
      vimMode: state.settings.vimMode,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const handleOpenFolder = useFileSystemStore.use.handleOpenFolder();
  const closeBufferForce = useBufferStore.use.actions().closeBufferForce;
  const whatsNewInitialized = useWhatsNewStore((state) => state.initialized);
  const whatsNewInfo = useWhatsNewStore((state) => state.info);
  const completeOnboarding = useOnboardingStore((state) => state.actions.complete);
  const viewModel = buildOnboardingViewModel(context, t);
  const [vimMode, setVimMode] = useState(settings.vimMode);
  const [openFoldersInNewWindow, setOpenFoldersInNewWindow] = useState(
    settings.openFoldersInNewWindow,
  );
  const [isImportDialogOpen, setIsImportDialogOpen] = useState(false);
  const [keybindingPreset, setKeybindingPreset] = useState<KeybindingPreset>(
    settings.keybindingPreset,
  );

  useEffect(() => {
    setVimMode(settings.vimMode);
    setOpenFoldersInNewWindow(settings.openFoldersInNewWindow);
    setKeybindingPreset(settings.keybindingPreset);
  }, [
    settings.keybindingPreset,
    settings.openFoldersInNewWindow,
    settings.vimMode,
  ]);

  const persistSelections = async () => {
    await Promise.all([
      updateSetting("vimMode", vimMode),
      updateSetting("openFoldersInNewWindow", openFoldersInNewWindow),
      updateSetting("askWhereToOpenProjects", false),
      updateSetting("keybindingPreset", keybindingPreset),
    ]);
  };

  const handleFinish = async (openFolderAfterFinish: boolean) => {
    if (viewModel.showSettings) {
      await persistSelections();
    }

    if (context.mode === "first-run" || context.mode === "updated") {
      const trackedContext = useOnboardingStore.getState().context;
      if (trackedContext?.currentVersion === context.currentVersion) {
        await completeOnboarding();
      } else {
        await markOnboardingCompleted(context.currentVersion);
      }
    }

    closeBufferForce(bufferId);

    if (openFolderAfterFinish) {
      await handleOpenFolder();
    }
  };

  const handlePrimaryAction = async () => {
    await handleFinish(viewModel.primaryAction === "open-folder");
  };

  const releaseInfo =
    whatsNewInfo?.version === context.currentVersion
      ? {
          ...whatsNewInfo,
          previousVersion: whatsNewInfo.previousVersion ?? context.previousVersion,
        }
      : {
          version: context.currentVersion,
          previousVersion: context.previousVersion,
        };

  return (
    <ScrollArea className="h-full w-full bg-background">
      <div className="mx-auto flex w-full max-w-205 flex-col px-8 py-10">
        <div className={viewModel.showSettings ? "mb-7" : "mb-6"}>
          <h1 className="font-sans ui-text-base font-semibold text-foreground">
            {viewModel.title}
          </h1>
          {viewModel.showSettings ? (
            <p className="font-sans ui-text-sm mt-2 text-muted-foreground">
              {viewModel.description}
            </p>
          ) : (
            <div className="font-sans ui-text-sm mt-2 flex flex-wrap items-center gap-x-2 text-muted-foreground">
              <span>{viewModel.description}</span>
              {releaseInfo.date ? (
                <>
                  <span aria-hidden="true">·</span>
                  <span>{t("onboarding.releasedDate", { date: formatReleaseDate(releaseInfo.date) })}</span>
                </>
              ) : null}
            </div>
          )}
        </div>

        {viewModel.showSettings ? (
          <Card className="gap-0 rounded-lg py-0">
            <SettingRow
              title={t("onboarding.keybindingPreset")}
              description={t(`onboarding.keybindingPreset.${keybindingPreset}.description`)}
            >
              <Select
                value={keybindingPreset}
                onChange={(value) => setKeybindingPreset(value as KeybindingPreset)}
                options={keybindingPresetOptions.map((option) => ({
                  ...option,
                  label: t(`onboarding.keybindingPreset.${option.value}.label`),
                }))}
                size="sm"
                variant="default"
                aria-label={t("onboarding.keybindingPreset")}
              />
            </SettingRow>

            <SettingRow title={t("onboarding.enableVimMode")}>
              <Switch checked={vimMode} onChange={setVimMode} />
            </SettingRow>

            <SettingRow title={t("onboarding.openFoldersInNewWindow")}>
              <Switch checked={openFoldersInNewWindow} onChange={setOpenFoldersInNewWindow} />
            </SettingRow>

            <SettingRow
              title={t("onboarding.importSettings")}
              description={t("onboarding.importSettingsDescription")}
            >
              <Button variant="default" onClick={() => setIsImportDialogOpen(true)}>
                {t("onboarding.import")}
              </Button>
            </SettingRow>
          </Card>
        ) : (
          <div className="min-w-0">
            <ReleaseNotesContent
              info={releaseInfo}
              loading={!whatsNewInitialized || whatsNewInfo?.version !== context.currentVersion}
            />
          </div>
        )}

        <div className="mt-6 flex items-center justify-end gap-2">
          {viewModel.secondaryLabel ? (
            <Button variant="ghost" onClick={() => void handleFinish(false)}>
              {viewModel.secondaryLabel}
            </Button>
          ) : null}
          <Button variant="accent" onClick={() => void handlePrimaryAction()}>
            {viewModel.primaryAction === "open-folder" && <FolderOpen />}
            {viewModel.primaryLabel}
          </Button>
        </div>
      </div>

      {isImportDialogOpen && (
        <IdeSettingsImportDialog onClose={() => setIsImportDialogOpen(false)} />
      )}
    </ScrollArea>
  );
}
