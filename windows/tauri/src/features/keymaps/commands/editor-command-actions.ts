import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useFoldStore } from "@/features/editor/stores/fold.store";
import { useInlineEditToolbarStore } from "@/features/editor/stores/inline-edit-toolbar.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import {
  readEditorClipboardText,
  writeEditorClipboardText,
} from "@/features/editor/utils/clipboard";
import { calculateCursorPositionFromContent } from "@/features/editor/utils/position";
import {
  resolveAllOccurrenceRanges,
  resolveSelectNextOccurrenceAction,
  resolveSelectPreviousOccurrenceAction,
  type OccurrenceRange,
} from "@/features/editor/utils/select-next-occurrence";
import { showChoiceDialog } from "@/ui/dialog";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { toast } from "sonner";
import { isEditorKeyboardTarget } from "../utils/editor-keyboard-target";

type EditorSelection = NonNullable<ReturnType<typeof editorAPI.getSelection>>;

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

function getActiveEditorBuffer() {
  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find((b) => b.id === bufferStore.activeBufferId);
  if (!activeBuffer || activeBuffer.type !== "editor" || activeBuffer.isVirtual) return null;
  return activeBuffer;
}

function getNormalizedEditorSelection(): EditorSelection | null {
  const selection = editorAPI.getSelection();
  if (!selection || selection.start.offset === selection.end.offset) return null;

  return selection.start.offset <= selection.end.offset
    ? selection
    : { start: selection.end, end: selection.start };
}

function shouldUseEditorModelCommand(): boolean {
  const activeElement = document.activeElement as HTMLElement | null;

  if (isEditorKeyboardTarget(activeElement)) {
    return true;
  }

  const isTextField =
    activeElement instanceof HTMLInputElement ||
    activeElement instanceof HTMLTextAreaElement ||
    activeElement?.isContentEditable;

  if (isTextField) return false;

  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find(
    (buffer) => buffer.id === bufferStore.activeBufferId,
  );

  return activeBuffer?.type === "editor";
}

function getSelectedEditorText(): string | null {
  const selection = getNormalizedEditorSelection();
  if (selection) {
    return editorAPI.getContent().slice(selection.start.offset, selection.end.offset);
  }

  const textarea = editorAPI.getTextareaRef();
  if (textarea && textarea.selectionStart !== textarea.selectionEnd) {
    const start = Math.min(textarea.selectionStart, textarea.selectionEnd);
    const end = Math.max(textarea.selectionStart, textarea.selectionEnd);
    return textarea.value.slice(start, end);
  }

  return null;
}

function selectEditorOffsets(start: number, end: number): void {
  const content = editorAPI.getContent();
  const startPosition = calculateCursorPositionFromContent(start, content);
  const endPosition = calculateCursorPositionFromContent(end, content);

  editorAPI.setCursorPosition(endPosition);
  editorAPI.setSelection({ start: startPosition, end: endPosition });

  const textarea = editorAPI.getTextareaRef();
  if (textarea?.value === content) {
    textarea.focus();
    textarea.selectionStart = start;
    textarea.selectionEnd = end;
  }
}

function addEditorOccurrence(direction: "next" | "previous"): void {
  const content = editorAPI.getContent();
  const editorState = useEditorStateStore.getState();
  const textarea = editorAPI.getTextareaRef();
  const textareaSelection =
    textarea?.value === content && textarea.selectionStart !== textarea.selectionEnd
      ? {
          start: Math.min(textarea.selectionStart, textarea.selectionEnd),
          end: Math.max(textarea.selectionStart, textarea.selectionEnd),
        }
      : null;
  const modelSelection = getNormalizedEditorSelection();
  const currentSelection = textareaSelection
    ? textareaSelection
    : modelSelection
      ? { start: modelSelection.start.offset, end: modelSelection.end.offset }
      : null;
  const selectedRanges =
    editorState.multiCursorState?.cursors.flatMap((cursor) =>
      cursor.selection
        ? [{ start: cursor.selection.start.offset, end: cursor.selection.end.offset }]
        : [],
    ) ?? [];
  const action =
    direction === "next"
      ? resolveSelectNextOccurrenceAction({
          content,
          cursorOffset: editorState.cursorPosition.offset,
          currentSelection,
          selectedRanges,
        })
      : resolveSelectPreviousOccurrenceAction({
          content,
          cursorOffset: editorState.cursorPosition.offset,
          currentSelection,
          selectedRanges,
        });

  if (!action) return;

  if (action.type === "select-initial") {
    selectEditorOffsets(action.range.start, action.range.end);
    return;
  }

  const toEditorRange = (range: OccurrenceRange) => {
    const start = calculateCursorPositionFromContent(range.start, content);
    const end = calculateCursorPositionFromContent(range.end, content);
    return { start, end };
  };
  const editorStateActions = useEditorStateStore.getState().actions;

  if (!useEditorStateStore.getState().multiCursorState && currentSelection) {
    const primarySelection = toEditorRange(action.searchRange);
    editorAPI.setCursorPosition(primarySelection.end);
    editorAPI.setSelection(primarySelection);
  }

  if (!useEditorStateStore.getState().multiCursorState) {
    editorStateActions.enableMultiCursor();
  }

  const nextSelection = toEditorRange(action.nextRange);
  editorStateActions.addCursor(nextSelection.end, nextSelection);
}

function selectAllEditorOccurrenceRanges(ranges: OccurrenceRange[]): void {
  const firstRange = ranges[0];
  if (!firstRange) return;

  const content = editorAPI.getContent();
  const editorStateActions = useEditorStateStore.getState().actions;
  const toEditorRange = (range: OccurrenceRange) => {
    const start = calculateCursorPositionFromContent(range.start, content);
    const end = calculateCursorPositionFromContent(range.end, content);
    return { start, end };
  };
  const firstSelection = toEditorRange(firstRange);

  editorStateActions.disableMultiCursor();
  editorAPI.setCursorPosition(firstSelection.end);
  editorAPI.setSelection(firstSelection);
  editorStateActions.enableMultiCursor();

  for (const range of ranges.slice(1)) {
    const selection = toEditorRange(range);
    editorStateActions.addCursor(selection.end, selection);
  }

  const textarea = editorAPI.getTextareaRef();
  if (textarea?.value === content) {
    textarea.focus();
    textarea.selectionStart = firstRange.start;
    textarea.selectionEnd = firstRange.end;
  }
}

export function selectAllActiveEditor(): void {
  if (!shouldUseEditorModelCommand()) {
    document.execCommand("selectAll");
    return;
  }

  editorAPI.selectAll();
}

export function undoActiveEditor(): void {
  editorAPI.undo();
}

export function redoActiveEditor(): void {
  editorAPI.redo();
}

export async function copyActiveEditorSelection(): Promise<void> {
  if (!shouldUseEditorModelCommand()) {
    document.execCommand("copy");
    return;
  }

  const selectedText = getSelectedEditorText();
  if (!selectedText) return;

  await writeEditorClipboardText(selectedText);
}

export async function cutActiveEditorSelection(): Promise<void> {
  if (!shouldUseEditorModelCommand()) {
    document.execCommand("cut");
    return;
  }

  const selectedText = getSelectedEditorText();
  const selection = getNormalizedEditorSelection();
  if (!selectedText || !selection) return;

  await writeEditorClipboardText(selectedText);
  editorAPI.deleteRange(selection);
}

export async function pasteIntoActiveEditor(): Promise<void> {
  if (!shouldUseEditorModelCommand()) {
    const text = await readEditorClipboardText();
    document.execCommand("insertText", false, text);
    return;
  }

  const text = await readEditorClipboardText();
  if (!text) return;

  const selection = getNormalizedEditorSelection();
  if (selection) {
    editorAPI.replaceRange(selection, text);
    return;
  }

  editorAPI.insertText(text);
}

export function selectNextEditorOccurrence(): void {
  if (editorAPI.addSelectionToNextFindMatch()) return;

  addEditorOccurrence("next");
}

export function selectPreviousEditorOccurrence(): void {
  if (editorAPI.addSelectionToPreviousFindMatch()) return;

  addEditorOccurrence("previous");
}

export function selectAllEditorOccurrences(): void {
  if (editorAPI.selectAllFindMatches()) return;

  const content = editorAPI.getContent();
  const editorState = useEditorStateStore.getState();
  const selection = getNormalizedEditorSelection();
  const ranges = resolveAllOccurrenceRanges({
    content,
    cursorOffset: editorState.cursorPosition.offset,
    selectionStart: selection?.start.offset,
    selectionEnd: selection?.end.offset,
  });
  if (ranges.length === 0) return;

  selectAllEditorOccurrenceRanges(ranges);
}

export function duplicateActiveEditorLine(): void {
  editorAPI.duplicateLine();
}

export function deleteActiveEditorLine(): void {
  editorAPI.deleteLine();
}

export function toggleActiveEditorComment(): void {
  editorAPI.toggleComment();
}

export function moveActiveEditorLineUp(): void {
  editorAPI.moveLineUp();
}

export function moveActiveEditorLineDown(): void {
  editorAPI.moveLineDown();
}

export function copyActiveEditorLineUp(): void {
  editorAPI.copyLineUp();
}

export function copyActiveEditorLineDown(): void {
  editorAPI.copyLineDown();
}

export function insertActiveEditorCursorAbove(): void {
  editorAPI.insertCursorAbove();
}

export function insertActiveEditorCursorBelow(): void {
  editorAPI.insertCursorBelow();
}

export function insertActiveEditorCursorsAtLineEnds(): void {
  editorAPI.insertCursorsAtLineEnds();
}

export function removeActiveEditorSecondaryCursors(): void {
  editorAPI.removeSecondaryCursors();
}

export function triggerActiveEditorSuggest(): void {
  window.dispatchEvent(new CustomEvent("editor-trigger-suggest"));
}

export function triggerActiveEditorParameterHints(): void {
  window.dispatchEvent(new CustomEvent("editor-trigger-signature-help"));
}

export function showInlineEditToolbar(): void {
  const editorState = useEditorStateStore.getState();
  const activeBufferId = useBufferStore.getState().activeBufferId;
  useInlineEditToolbarStore
    .getState()
    .actions.show(editorState.activeEditorViewKey ?? activeBufferId ?? null);
}

export function goToActiveEditorMatchingBracket(): void {
  editorAPI.goToMatchingBracket();
}

export function selectToActiveEditorBracket(): void {
  editorAPI.selectToBracket();
}

export function removeActiveEditorBrackets(): void {
  editorAPI.removeBrackets();
}

export function expandActiveEditorSelection(): void {
  editorAPI.expandSelection();
}

export function shrinkActiveEditorSelection(): void {
  editorAPI.shrinkSelection();
}

export function triggerActiveEditorRenameSymbol(): void {
  window.dispatchEvent(new CustomEvent("editor-rename-symbol"));
}

export async function formatActiveEditorDocument(): Promise<void> {
  const bufferStore = useBufferStore.getState();
  const activeBuffer = getActiveEditorBuffer();

  if (!activeBuffer) {
    toast.warning(getCurrentTranslator()("editorCommands.noEditableFileToFormat"));
    return;
  }

  const { formatContent, isFormattingAvailable } =
    await import("@/features/editor/formatter/formatter-service");
  const languageId = extensionRegistry.getLanguageId(activeBuffer.path) || activeBuffer.language;

  if (!isFormattingAvailable(activeBuffer.path, languageId || undefined)) {
    toast.warning(getCurrentTranslator()("editorCommands.noFormatterConfigured"));
    return;
  }

  const result = await formatContent({
    filePath: activeBuffer.path,
    content: activeBuffer.content,
    languageId: languageId || undefined,
  });

  if (!result.success || result.formattedContent === undefined) {
    toast.error(result.error || getCurrentTranslator()("editorCommands.formattingFailed"));
    return;
  }

  if (result.formattedContent === activeBuffer.content) {
    toast.info(getCurrentTranslator()("editorCommands.documentAlreadyFormatted"));
    return;
  }

  bufferStore.actions.updateBufferContent(activeBuffer.id, result.formattedContent, true);
  toast.success(getCurrentTranslator()("editorCommands.documentFormatted"));
}

export async function formatActiveEditorSelection(): Promise<void> {
  const selection = getNormalizedEditorSelection();
  if (!selection) {
    toast.warning(getCurrentTranslator()("editorCommands.selectTextToFormat"));
    return;
  }

  const bufferStore = useBufferStore.getState();
  const activeBuffer = getActiveEditorBuffer();

  if (!activeBuffer) {
    toast.warning(getCurrentTranslator()("editorCommands.noEditableFileToFormat"));
    return;
  }

  const { formatRange } = await import("@/features/editor/formatter/formatter-service");
  const result = await formatRange({
    filePath: activeBuffer.path,
    content: activeBuffer.content,
    languageId:
      extensionRegistry.getLanguageId(activeBuffer.path) || activeBuffer.language || undefined,
    range: {
      start: { line: selection.start.line, character: selection.start.column },
      end: { line: selection.end.line, character: selection.end.column },
    },
  });

  if (!result.success || result.formattedContent === undefined) {
    toast.error(result.error || getCurrentTranslator()("editorCommands.selectionFormattingFailed"));
    return;
  }

  if (result.formattedContent === activeBuffer.content) {
    toast.info(getCurrentTranslator()("editorCommands.selectionAlreadyFormatted"));
    return;
  }

  bufferStore.actions.updateBufferContent(activeBuffer.id, result.formattedContent, true);
  const nextCursor = calculateCursorPositionFromContent(
    Math.min(selection.start.offset, result.formattedContent.length),
    result.formattedContent,
  );
  editorAPI.setCursorPosition(nextCursor);
  editorAPI.setSelection(undefined);
  toast.success(getCurrentTranslator()("editorCommands.selectionFormatted"));
}

export async function showHoverForActiveEditor(): Promise<void> {
  window.dispatchEvent(new CustomEvent("editor-show-hover"));
}

export async function runQuickFixForActiveEditor(): Promise<void> {
  const activeBuffer = getActiveEditorBuffer();

  if (!activeBuffer) {
    toast.warning(getCurrentTranslator()("editorCommands.noEditableFileForQuickFixes"));
    return;
  }

  const { useDiagnosticsStore } = await import("@/features/diagnostics/stores/diagnostics.store");
  const { selectDiagnosticForQuickFix, selectPreferredCodeAction } =
    await import("@/features/diagnostics/utils/quick-fix");
  const diagnostics = useDiagnosticsStore
    .getState()
    .actions.getDiagnosticsForFile(activeBuffer.path);
  const diagnostic = selectDiagnosticForQuickFix(diagnostics, editorAPI.getCursorPosition());

  if (!diagnostic) {
    toast.info(getCurrentTranslator()("editorCommands.noDiagnosticAtCursor"));
    return;
  }

  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const lspClient = LspClient.getInstance();
  const codeActions = (await lspClient.getCodeActions(activeBuffer.path, diagnostic)).filter(
    (action) => !action.disabledReason,
  );

  if (codeActions.length === 0) {
    toast.info(getCurrentTranslator()("editorCommands.noQuickFixes"));
    return;
  }

  const preferredAction = selectPreferredCodeAction(codeActions);
  const action =
    codeActions.length === 1
      ? codeActions[0]
      : await (async () => {
          const t = getCurrentTranslator();
          const selected = await showChoiceDialog(t("editorCommands.chooseQuickFixPrompt"), {
            title: t("editor.quickFix"),
            choices: codeActions.slice(0, 8).map((codeAction, index) => ({
              value: String(index),
              label: codeAction.isPreferred
                ? t("editorCommands.preferredAction", { title: codeAction.title })
                : codeAction.title,
            })),
          });

          return selected === null ? null : codeActions[Number(selected)] || null;
        })();

  const actionToApply = action ?? (codeActions.length === 1 ? preferredAction : null);
  if (!actionToApply) return;

  const result = await lspClient.applyCodeAction(activeBuffer.path, actionToApply.payload);
  if (result.applied) {
    toast.success(getCurrentTranslator()("editorCommands.appliedAction", { title: actionToApply.title }));
  } else {
    toast.warning(
      result.reason ||
        getCurrentTranslator()("editorCommands.unableToApplyAction", {
          title: actionToApply.title,
        }),
    );
  }
}

export function foldAllActiveEditor(): void {
  const activeBuffer = getActiveEditorBuffer();
  if (!activeBuffer) {
    toast.warning(getCurrentTranslator()("editorCommands.noFoldableEditor"));
    return;
  }

  const foldActions = useFoldStore.getState().actions;
  foldActions.computeFoldRegions(activeBuffer.path, activeBuffer.content);
  foldActions.foldAll(activeBuffer.path);
}

export function foldLevelActiveEditor(level: number): void {
  const activeBuffer = getActiveEditorBuffer();
  if (!activeBuffer) {
    toast.warning(getCurrentTranslator()("editorCommands.noFoldableEditor"));
    return;
  }

  const foldActions = useFoldStore.getState().actions;
  foldActions.computeFoldRegions(activeBuffer.path, activeBuffer.content);
  foldActions.foldLevel(activeBuffer.path, level);
}

export function unfoldAllActiveEditor(): void {
  const activeBuffer = getActiveEditorBuffer();
  if (!activeBuffer) {
    toast.warning(getCurrentTranslator()("editorCommands.noFoldableEditor"));
    return;
  }

  useFoldStore.getState().actions.unfoldAll(activeBuffer.path);
}
