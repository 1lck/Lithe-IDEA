import type { CompletionItem, MarkupContent } from "vscode-languageserver-protocol";

export interface MonacoSuggestRange {
  startLineNumber: number;
  startColumn: number;
  endLineNumber: number;
  endColumn: number;
}

export interface MonacoAdditionalTextEdit {
  range: MonacoSuggestRange;
  text: string;
}

export interface MonacoCompletionLabel {
  label: string;
  detail?: string;
  description?: string;
}

export interface MonacoCompletionSuggestion {
  label: string | MonacoCompletionLabel;
  insertText: string;
  range: MonacoSuggestRange;
  detail?: string;
  documentation?: string | { value: string };
  filterText?: string;
  sortText?: string;
  additionalTextEdits?: MonacoAdditionalTextEdit[];
  snippet: boolean;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isLspRange(
  value: unknown,
): value is { start: { line: number; character: number }; end: { line: number; character: number } } {
  return (
    isObject(value) &&
    isObject(value.start) &&
    typeof value.start.line === "number" &&
    typeof value.start.character === "number" &&
    isObject(value.end) &&
    typeof value.end.line === "number" &&
    typeof value.end.character === "number"
  );
}

export function lspRangeToMonacoRange(range: {
  start: { line: number; character: number };
  end: { line: number; character: number };
}): MonacoSuggestRange {
  return {
    startLineNumber: range.start.line + 1,
    startColumn: range.start.character + 1,
    endLineNumber: range.end.line + 1,
    endColumn: range.end.character + 1,
  };
}

export function completionLabelText(item: CompletionItem): string {
  return typeof item.label === "string" ? item.label : String(item.label ?? "");
}

export const LSP_COMPLETION_ORIGIN = "__litheLspOrigin";

export interface LspCompletionOrigin<TTarget = unknown> {
  item: CompletionItem;
  target: TTarget;
  range: MonacoSuggestRange;
}

export function attachLspCompletionOrigin<T extends object, TTarget>(
  suggestion: T,
  origin: LspCompletionOrigin<TTarget>,
): T {
  (suggestion as T & Record<typeof LSP_COMPLETION_ORIGIN, LspCompletionOrigin<TTarget>>)[
    LSP_COMPLETION_ORIGIN
  ] = origin;
  return suggestion;
}

export function lspCompletionOrigin<TTarget>(item: object): LspCompletionOrigin<TTarget> | undefined {
  return (item as Record<typeof LSP_COMPLETION_ORIGIN, LspCompletionOrigin<TTarget> | undefined>)[
    LSP_COMPLETION_ORIGIN
  ];
}

export function monacoCompletionLabel(item: CompletionItem): string | MonacoCompletionLabel {
  const label = completionLabelText(item);
  const details = item.labelDetails;
  if (details && (details.detail || details.description)) {
    return {
      label,
      detail: details.detail,
      description: details.description,
    };
  }
  if (item.detail && item.detail !== label) {
    return { label, description: item.detail };
  }
  return label;
}

export function monacoInsertText(item: CompletionItem): string {
  if (item.textEdit && "newText" in item.textEdit) {
    return item.textEdit.newText;
  }
  return item.insertText || completionLabelText(item);
}

export function monacoCompletionRange(
  item: CompletionItem,
  fallback: MonacoSuggestRange,
): MonacoSuggestRange {
  if (item.textEdit && "range" in item.textEdit && isLspRange(item.textEdit.range)) {
    return lspRangeToMonacoRange(item.textEdit.range);
  }
  return fallback;
}

export function monacoAdditionalTextEdits(item: CompletionItem): MonacoAdditionalTextEdit[] {
  return (item.additionalTextEdits ?? [])
    .filter((edit) => typeof edit.newText === "string" && isLspRange(edit.range))
    .map((edit) => ({
      range: lspRangeToMonacoRange(edit.range),
      text: edit.newText,
    }));
}

function markupDocumentation(
  documentation: CompletionItem["documentation"],
): string | { value: string } | undefined {
  if (!documentation) return undefined;
  if (typeof documentation === "string") return documentation;
  const markup = documentation as MarkupContent;
  if (typeof markup.value === "string") return { value: markup.value };
  return undefined;
}

export function toMonacoCompletionSuggestion(
  item: CompletionItem,
  fallbackRange: MonacoSuggestRange,
): MonacoCompletionSuggestion {
  const additionalTextEdits = monacoAdditionalTextEdits(item);
  return {
    label: monacoCompletionLabel(item),
    insertText: monacoInsertText(item),
    range: monacoCompletionRange(item, fallbackRange),
    detail: item.detail,
    documentation: markupDocumentation(item.documentation),
    filterText: item.filterText,
    sortText: item.sortText,
    ...(additionalTextEdits.length > 0 ? { additionalTextEdits } : {}),
    snippet: item.insertTextFormat === 2,
  };
}

export function mergeResolvedCompletionSuggestion(
  current: MonacoCompletionSuggestion,
  resolved: CompletionItem,
  fallbackRange: MonacoSuggestRange,
): MonacoCompletionSuggestion {
  const next = toMonacoCompletionSuggestion(resolved, fallbackRange);
  const additionalTextEdits =
    next.additionalTextEdits && next.additionalTextEdits.length > 0
      ? next.additionalTextEdits
      : current.additionalTextEdits;
  const resolvedHasRange = Boolean(
    resolved.textEdit && "range" in resolved.textEdit && isLspRange(resolved.textEdit.range),
  );
  const resolvedHasLabelDetails = Boolean(
    resolved.labelDetails?.detail || resolved.labelDetails?.description,
  );
  return {
    ...current,
    label: resolvedHasLabelDetails
      ? next.label
      : typeof current.label === "object"
        ? current.label
        : next.label,
    insertText: next.insertText || current.insertText,
    range: resolvedHasRange ? next.range : current.range,
    detail: next.detail ?? current.detail,
    documentation: next.documentation ?? current.documentation,
    filterText: next.filterText ?? current.filterText,
    sortText: next.sortText ?? current.sortText,
    additionalTextEdits,
    snippet: next.snippet || current.snippet,
  };
}
