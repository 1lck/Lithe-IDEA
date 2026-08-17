import {
  TextAlignLeftIcon as AlignLeft,
  BookmarkIcon as Bookmark,
  TextAaIcon as CaseSensitive,
  CaretDownIcon as ChevronDown,
  CaretUpIcon as ChevronUp,
  ClipboardTextIcon as ClipboardPaste,
  CodeIcon as Code,
  CopyIcon as Copy,
  FileTextIcon as FileText,
  TextIndentIcon as Indent,
  TextOutdentIcon as Outdent,
  PencilLineIcon as PenLine,
  ArrowCounterClockwiseIcon as RotateCcw,
  ScissorsIcon as Scissors,
  MagnifyingGlassIcon as Search,
  TrashIcon as Trash2,
  TextTIcon as Type,
} from "@/ui/icons";
import type { MenuItem } from "@/ui/dropdown";
import Keybinding from "@/features/keymaps/components/keybinding";

export interface EditorContextMenuHandlers {
  onCopy?: () => void;
  onCut?: () => void;
  onPaste?: () => void;
  onSelectAll?: () => void;
  onFind?: () => void;
  onGoToLine?: () => void;
  onGoToDefinition?: () => void;
  onGoToTypeDefinition?: () => void;
  onFindReferences?: () => void;
  onRenameSymbol?: () => void;
  onSelectNextOccurrence?: () => void;
  onSelectAllOccurrences?: () => void;
  onDelete?: () => void;
  onDuplicate?: () => void;
  onIndent?: () => void;
  onOutdent?: () => void;
  onToggleComment?: () => void;
  onFormat?: () => void;
  onFormatSelection?: () => void;
  onTriggerSuggest?: () => void;
  onShowHover?: () => void;
  onQuickFix?: () => void;
  onToggleCase?: () => void;
  onMoveLineUp?: () => void;
  onMoveLineDown?: () => void;
  onToggleBookmark?: () => void;
}

export interface EditorContextMenuItemOptions extends EditorContextMenuHandlers {
  hasSelection: boolean;
  modifierKey: string;
  altKey: string;
  t: (key: string) => string;
}

const noop = () => {};

function separator(id: string): MenuItem {
  return { id, label: "", separator: true, onClick: noop };
}

function isDisabled(handler: (() => void) | undefined, disabled = false): boolean {
  return disabled || !handler;
}

export function buildEditorContextMenuItems({
  hasSelection,
  modifierKey,
  altKey,
  t,
  onCopy,
  onCut,
  onPaste,
  onSelectAll,
  onFind,
  onGoToLine,
  onGoToDefinition,
  onGoToTypeDefinition,
  onFindReferences,
  onRenameSymbol,
  onSelectNextOccurrence,
  onSelectAllOccurrences,
  onDelete,
  onDuplicate,
  onIndent,
  onOutdent,
  onToggleComment,
  onFormat,
  onFormatSelection,
  onTriggerSuggest,
  onShowHover,
  onQuickFix,
  onToggleCase,
  onMoveLineUp,
  onMoveLineDown,
  onToggleBookmark,
}: EditorContextMenuItemOptions): MenuItem[] {
  return [
    {
      id: "copy",
      label: t("files.copy"),
      icon: <Copy />,
      keybinding: <Keybinding keys={[modifierKey, "C"]} className="opacity-60" />,
      disabled: isDisabled(onCopy, !hasSelection),
      onClick: onCopy ?? noop,
    },
    {
      id: "cut",
      label: t("files.cut"),
      icon: <Scissors />,
      keybinding: <Keybinding keys={[modifierKey, "X"]} className="opacity-60" />,
      disabled: isDisabled(onCut, !hasSelection),
      onClick: onCut ?? noop,
    },
    {
      id: "paste",
      label: t("files.paste"),
      icon: <ClipboardPaste />,
      keybinding: <Keybinding keys={[modifierKey, "V"]} className="opacity-60" />,
      disabled: isDisabled(onPaste),
      onClick: onPaste ?? noop,
    },
    {
      id: "delete",
      label: t("files.delete"),
      icon: <Trash2 />,
      keybinding: <Keybinding keys={["Del"]} className="opacity-60" />,
      disabled: isDisabled(onDelete, !hasSelection),
      onClick: onDelete ?? noop,
    },
    separator("sep-1"),
    {
      id: "select-all",
      label: t("editor.selectAll"),
      icon: <Type />,
      keybinding: <Keybinding keys={[modifierKey, "A"]} className="opacity-60" />,
      disabled: isDisabled(onSelectAll),
      onClick: onSelectAll ?? noop,
    },
    {
      id: "duplicate",
      label: t("editor.duplicateLine"),
      icon: <FileText />,
      disabled: isDisabled(onDuplicate),
      onClick: onDuplicate ?? noop,
    },
    {
      id: "select-next-occurrence",
      label: t("editor.addSelectionToNextMatch"),
      icon: <Search />,
      keybinding: <Keybinding keys={[modifierKey, "D"]} className="opacity-60" />,
      disabled: isDisabled(onSelectNextOccurrence),
      onClick: onSelectNextOccurrence ?? noop,
    },
    {
      id: "select-all-occurrences",
      label: t("editor.selectAllOccurrences"),
      icon: <Search />,
      keybinding: <Keybinding keys={[modifierKey, "Shift", "L"]} className="opacity-60" />,
      disabled: isDisabled(onSelectAllOccurrences),
      onClick: onSelectAllOccurrences ?? noop,
    },
    separator("sep-2"),
    {
      id: "toggle-comment",
      label: t("editor.toggleComment"),
      icon: <Code />,
      keybinding: <Keybinding keys={[modifierKey, "/"]} className="opacity-60" />,
      disabled: isDisabled(onToggleComment),
      onClick: onToggleComment ?? noop,
    },
    {
      id: "indent",
      label: t("editor.indent"),
      icon: <Indent />,
      keybinding: <Keybinding keys={["Tab"]} className="opacity-60" />,
      disabled: isDisabled(onIndent),
      onClick: onIndent ?? noop,
    },
    {
      id: "outdent",
      label: t("editor.outdent"),
      icon: <Outdent />,
      keybinding: <Keybinding keys={["Shift", "Tab"]} className="opacity-60" />,
      disabled: isDisabled(onOutdent),
      onClick: onOutdent ?? noop,
    },
    {
      id: "format",
      label: t("editor.formatDocument"),
      icon: <AlignLeft />,
      keybinding: <Keybinding keys={["Shift", altKey, "F"]} className="opacity-60" />,
      disabled: isDisabled(onFormat),
      onClick: onFormat ?? noop,
    },
    {
      id: "format-selection",
      label: t("editor.formatSelection"),
      icon: <AlignLeft />,
      keybinding: <Keybinding keys={[modifierKey, "K", modifierKey, "F"]} className="opacity-60" />,
      disabled: isDisabled(onFormatSelection, !hasSelection),
      onClick: onFormatSelection ?? noop,
    },
    separator("sep-3"),
    {
      id: "move-up",
      label: t("editor.moveLineUp"),
      icon: <ChevronUp />,
      keybinding: <Keybinding keys={[altKey, "Up"]} className="opacity-60" />,
      disabled: isDisabled(onMoveLineUp),
      onClick: onMoveLineUp ?? noop,
    },
    {
      id: "move-down",
      label: t("editor.moveLineDown"),
      icon: <ChevronDown />,
      keybinding: <Keybinding keys={[altKey, "Down"]} className="opacity-60" />,
      disabled: isDisabled(onMoveLineDown),
      onClick: onMoveLineDown ?? noop,
    },
    {
      id: "toggle-case",
      label: t("editor.toggleCase"),
      icon: <CaseSensitive />,
      disabled: isDisabled(onToggleCase, !hasSelection),
      onClick: onToggleCase ?? noop,
    },
    separator("sep-4"),
    {
      id: "go-to-definition",
      label: t("editor.goToDefinition"),
      icon: <Code />,
      keybinding: <Keybinding keys={["F12"]} className="opacity-60" />,
      disabled: isDisabled(onGoToDefinition),
      onClick: onGoToDefinition ?? noop,
    },
    {
      id: "find-references",
      label: t("editor.findAllReferences"),
      icon: <Search />,
      keybinding: <Keybinding keys={["Shift", "F12"]} className="opacity-60" />,
      disabled: isDisabled(onFindReferences),
      onClick: onFindReferences ?? noop,
    },
    {
      id: "go-to-type-definition",
      label: t("editor.goToTypeDefinition"),
      icon: <Code />,
      disabled: isDisabled(onGoToTypeDefinition),
      onClick: onGoToTypeDefinition ?? noop,
    },
    {
      id: "rename-symbol",
      label: t("editor.renameSymbol"),
      icon: <PenLine />,
      keybinding: <Keybinding keys={["F2"]} className="opacity-60" />,
      disabled: isDisabled(onRenameSymbol),
      onClick: onRenameSymbol ?? noop,
    },
    {
      id: "quick-fix",
      label: t("editor.quickFix"),
      icon: <PenLine />,
      keybinding: <Keybinding keys={[modifierKey, "."]} className="opacity-60" />,
      disabled: isDisabled(onQuickFix),
      onClick: onQuickFix ?? noop,
    },
    {
      id: "show-hover",
      label: t("editor.showHover"),
      icon: <Code />,
      keybinding: <Keybinding keys={[modifierKey, "K", modifierKey, "I"]} className="opacity-60" />,
      disabled: isDisabled(onShowHover),
      onClick: onShowHover ?? noop,
    },
    {
      id: "trigger-suggest",
      label: t("editor.triggerSuggest"),
      icon: <Code />,
      keybinding: <Keybinding keys={["Ctrl", "Space"]} className="opacity-60" />,
      disabled: isDisabled(onTriggerSuggest),
      onClick: onTriggerSuggest ?? noop,
    },
    separator("sep-5"),
    {
      id: "find",
      label: t("editor.find"),
      icon: <Search />,
      keybinding: <Keybinding keys={[modifierKey, "F"]} className="opacity-60" />,
      disabled: isDisabled(onFind),
      onClick: onFind ?? noop,
    },
    {
      id: "go-to-line",
      label: t("editor.goToLine"),
      icon: <RotateCcw />,
      keybinding: <Keybinding keys={[modifierKey, "G"]} className="opacity-60" />,
      disabled: isDisabled(onGoToLine),
      onClick: onGoToLine ?? noop,
    },
    {
      id: "bookmark",
      label: t("editor.toggleBookmark"),
      icon: <Bookmark />,
      keybinding: <Keybinding keys={[modifierKey, "K", modifierKey, "K"]} className="opacity-60" />,
      disabled: isDisabled(onToggleBookmark),
      onClick: onToggleBookmark ?? noop,
    },
  ];
}
