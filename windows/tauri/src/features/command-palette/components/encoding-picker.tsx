import { useMemo, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorAppStore } from "@/features/editor/stores/editor-app.store";
import { canReopenWithEncoding, canSaveWithEncoding, reopenDocumentWithEncoding } from "@/features/editor/services/document-encoding-workflow";
import { FILE_ENCODINGS, readDocumentFileDetails, type FileEncoding } from "@/platform/document-files";
import { showAlertDialog, showChoiceDialog } from "@/ui/dialog";
import { CommandEmpty, CommandHeader, CommandHeaderAction, CommandInput, CommandItemBadge, CommandItemRow, CommandList, useCommandListNavigation } from "@/ui/command";
import { CaretLeftIcon as CaretLeft } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import { getEncodingPickerMode, type EncodingPickerMode } from "../services/encoding-picker-state";

export function EncodingPickerContent({ onClose, onBack }: { onClose: () => void; onBack: () => void }) {
  const { t } = useTranslation();
  const [mode, setMode] = useState<EncodingPickerMode>(getEncodingPickerMode);
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const activeBufferId = useBufferStore.use.activeBufferId();
  const buffer = useBufferStore((state) => activeBufferId ? state.buffers.find((item) => item.id === activeBufferId) : null);
  const editorActions = useEditorAppStore.use.actions();
  const bufferActions = useBufferStore.use.actions();
  const filtered = useMemo(() => FILE_ENCODINGS.filter((encoding) => encoding.toLowerCase().includes(query.toLowerCase())), [query]);
  const { selectedIndex, setSelectedIndex, onInputKeyDown } = useCommandListNavigation({
    itemCount: filtered.length,
    resetKey: `${mode}:${query}`,
    onSelect: (index) => void selectEncoding(filtered[index]),
  });
  const chooseNavigation = useCommandListNavigation({
    itemCount: 2,
    resetKey: "choose",
    onSelect: (index) => setMode(index === 0 ? "reopen" : "save"),
  });

  function goBack() {
    if (mode === "choose") onBack();
    else { setMode("choose"); setQuery(""); }
  }

  async function selectEncoding(encoding: FileEncoding | undefined) {
    if (!encoding || !buffer || buffer.type !== "editor") return;
    if (mode === "reopen") {
      if (!canReopenWithEncoding(buffer)) return;
      setBusy(true);
      try {
        const result = await reopenDocumentWithEncoding(encoding, {
          snapshot: () => {
            const current = useBufferStore.getState().buffers.find((item) => item.id === buffer.id);
            return current?.type === "editor" ? current : null;
          },
          isCurrent: () => useBufferStore.getState().activeBufferId === buffer.id,
          chooseDirtyAction: async () => showChoiceDialog(t("editor.encodingReopenDirty"), {
            title: t("editor.encodingReopenTitle"),
            choices: [
              { value: "save", label: t("ui.save"), variant: "accent" },
              { value: "discard", label: t("editor.encodingDiscard") },
            ],
          }),
          save: () => editorActions.handleSave(buffer.id),
          read: (path, selectedEncoding) => readDocumentFileDetails(path, selectedEncoding),
          replace: (source, details) => bufferActions.replaceBufferFromDisk(source.id, source.path, source.contentRevision ?? 0, details.content, details.encoding, details.identity),
        });
        if (result) onClose();
      } catch (error) {
        await showAlertDialog(error instanceof Error ? error.message : t("editor.encodingFailed"), t("editor.encodingFailed"));
      } finally { setBusy(false); }
      return;
    }
    if (!canSaveWithEncoding(buffer)) return;
    setBusy(true);
    try {
      if (await editorActions.saveWithEncoding(encoding, buffer.id) === "saved") onClose();
    } finally { setBusy(false); }
  }

  if (mode === "choose") {
    const reopenDisabled = !buffer || buffer.type !== "editor" || !canReopenWithEncoding(buffer);
    const saveDisabled = !buffer || buffer.type !== "editor" || !canSaveWithEncoding(buffer);
    return <>
      <CommandHeader onClose={onClose}>
        <CommandHeaderAction aria-label={t("commandPalette.backToCommands")} onClick={onBack}><CaretLeft /></CommandHeaderAction>
        <CommandInput value={query} onChange={setQuery} onKeyDown={chooseNavigation.onInputKeyDown} placeholder={t("commandPalette.placeholder")} />
      </CommandHeader>
      <CommandList>
        <CommandItemRow title={t("editor.reopenWithEncoding")} isSelected={chooseNavigation.selectedIndex === 0} accessory={buffer?.type === "editor" ? <CommandItemBadge>{buffer.encoding ?? "UTF-8"}</CommandItemBadge> : undefined} disabled={reopenDisabled} onMouseEnter={() => chooseNavigation.setSelectedIndex(0)} onClick={() => setMode("reopen")} />
        <CommandItemRow title={t("editor.saveWithEncoding")} isSelected={chooseNavigation.selectedIndex === 1} accessory={buffer?.type === "editor" ? <CommandItemBadge>{buffer.encoding ?? "UTF-8"}</CommandItemBadge> : undefined} disabled={saveDisabled} onMouseEnter={() => chooseNavigation.setSelectedIndex(1)} onClick={() => setMode("save")} />
      </CommandList>
    </>;
  }

  return <>
    <CommandHeader onClose={onClose}>
      <CommandHeaderAction aria-label={t("commandPalette.backToCommands")} onClick={goBack}><CaretLeft /></CommandHeaderAction>
      <CommandInput value={query} onChange={setQuery} onKeyDown={onInputKeyDown} placeholder={t("commandPalette.placeholder")} disabled={busy} />
    </CommandHeader>
    <CommandList>
      {filtered.length === 0 ? <CommandEmpty>{t("commandPalette.noCommands")}</CommandEmpty> : filtered.map((encoding, index) => <CommandItemRow key={encoding} title={encoding} isSelected={index === selectedIndex} disabled={busy} onMouseEnter={() => setSelectedIndex(index)} onClick={() => void selectEncoding(encoding)} />)}
    </CommandList>
  </>;
}
