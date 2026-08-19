import { getBufferById } from "@/features/editor/utils/buffer-index";
import { isEditorContent, type PaneContent } from "@/features/panes/types/pane-content.types";
import { createTranslator, type DisplayLanguage } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { showChoiceDialog } from "@/ui/dialog";
import { toast } from "sonner";

export type ProjectTransitionAction =
  | "switching projects"
  | "closing this project"
  | "restarting to update";

type UnsavedProjectTransitionChoice = "cancel" | "discard" | "save";

export const getDirtyEditorBuffers = (buffers: PaneContent[]) =>
  buffers.filter((buffer) => isEditorContent(buffer) && buffer.isDirty);

export const getUnsavedProjectTransitionMessage = (
  action: ProjectTransitionAction,
  buffers: PaneContent[],
  language: DisplayLanguage = "en-US",
) => {
  const t = createTranslator(language);
  const dirtyBuffers = getDirtyEditorBuffers(buffers);

  if (dirtyBuffers.length === 0) {
    return null;
  }

  if (dirtyBuffers.length === 1) {
    return t("unsavedProjectTransition.messageOne", {
      file: dirtyBuffers[0].name,
      action: t(`unsavedProjectTransition.action.${action}`),
    });
  }

  return t("unsavedProjectTransition.messageMany", {
    count: dirtyBuffers.length,
    action: t(`unsavedProjectTransition.action.${action}`),
  });
};

const saveDirtyEditorBuffers = async (dirtyBuffers: PaneContent[], t: ReturnType<typeof createTranslator>) => {
  const { useBufferStore } = await import("@/features/editor/stores/buffer.store");
  const { useEditorAppStore } = await import("@/features/editor/stores/editor-app.store");
  const { setActiveBuffer } = useBufferStore.getState().actions;
  const { handleSave } = useEditorAppStore.getState().actions;

  for (const dirtyBuffer of dirtyBuffers) {
    const currentBuffer = getBufferById(useBufferStore.getState().buffers, dirtyBuffer.id);

    if (!currentBuffer || !isEditorContent(currentBuffer) || !currentBuffer.isDirty) {
      continue;
    }

    setActiveBuffer(currentBuffer.id);
    await handleSave();

    const savedBuffer = getBufferById(useBufferStore.getState().buffers, currentBuffer.id);

    if (savedBuffer && isEditorContent(savedBuffer) && savedBuffer.isDirty) {
      toast.warning(t("unsavedProjectTransition.saveBeforeContinuing", { file: savedBuffer.name }));
      return false;
    }
  }

  const remainingDirtyBuffers = getDirtyEditorBuffers(useBufferStore.getState().buffers);
  if (remainingDirtyBuffers.length > 0) {
    toast.warning(
      t("unsavedProjectTransition.saveOrCloseBeforeContinuing", {
        count: remainingDirtyBuffers.length,
      }),
    );
    return false;
  }

  return true;
};

export const prepareProjectTransitionWithUnsavedBuffers = async (
  action: ProjectTransitionAction,
  buffers: PaneContent[],
) => {
  const dirtyBuffers = getDirtyEditorBuffers(buffers);
  if (dirtyBuffers.length === 0) {
    return true;
  }

  const language = useSettingsStore.getState().settings.displayLanguage;
  const t = createTranslator(language);
  const message = getUnsavedProjectTransitionMessage(action, dirtyBuffers, language);
  if (!message) {
    return true;
  }

  const choice = await showChoiceDialog<UnsavedProjectTransitionChoice>(message, {
    title: t("unsavedChanges.title"),
    choices: [
      { value: "cancel", label: t("ui.cancel"), variant: "default" },
      {
        value: "discard",
        label:
          dirtyBuffers.length === 1
            ? t("unsavedChanges.doNotSave")
            : t("unsavedProjectTransition.discardAll"),
        variant: "default",
      },
      {
        value: "save",
        label: dirtyBuffers.length === 1 ? t("ui.save") : t("unsavedProjectTransition.saveAll"),
        variant: "accent",
      },
    ],
  });

  if (choice === "discard") {
    return true;
  }

  if (choice !== "save") {
    return false;
  }

  return await saveDirtyEditorBuffers(dirtyBuffers, t);
};
