import type { SpringProperty } from "../types/spring.types";
import { pathStartsWithRoot } from "@/utils/path-helpers";

/** Presentation-only key edits. Property names and descriptions belong to the
 * existing Core Spring metadata index, shared with the macOS product. */
export function springPropertyCompletions(args: {
  filePath: string;
  root: string | null;
  properties: readonly SpringProperty[];
  line: string;
  previousLine?: string;
  lineNumber: number;
  column: number;
}) {
  const empty = { suggestions: [] as SpringPropertySuggestion[], incomplete: false };
  if (!args.root || !pathStartsWithRoot(args.filePath, args.root)) return empty;
  const name = args.filePath.replace(/\\/g, "/").split("/").slice(-1)[0] ?? "";
  if (!/^application(?:-[^/]+)?\.properties$/i.test(name)) return empty;
  // A continued value is not a new property key.
  const trailingSlashes = args.previousLine?.match(/\\+$/)?.[0].length ?? 0;
  if (trailingSlashes % 2 === 1) return empty;
  const match = /^(\s*)([\p{L}\p{N}_.\-[\]]*)/u.exec(args.line);
  if (!match) return empty;
  const start = match[1].length;
  const end = start + match[2].length;
  const cursor = args.column - 1;
  if (cursor < start || cursor > end) return empty;
  const rest = args.line.slice(end);
  if (rest && !/^[\s=:]/.test(rest)) return empty;
  const prefix = args.line.slice(start, cursor).toLowerCase();
  const matching = args.properties.filter((property) =>
    property.name.toLowerCase().startsWith(prefix),
  );
  const existingSeparator = /^[\s=:]/.test(rest);
  return {
    incomplete: matching.length > 200,
    suggestions: matching.slice(0, 200).map(
      (property): SpringPropertySuggestion => ({
        label: property.name,
        insertText: property.name + (existingSeparator ? "" : "="),
        detail: [
          property.typeName,
          property.defaultValue == null ? null : `= ${property.defaultValue}`,
        ]
          .filter(Boolean)
          .join(" "),
        documentation: property.description ?? undefined,
        filterText: property.name,
        sortText: property.name,
        range: {
          startLineNumber: args.lineNumber,
          endLineNumber: args.lineNumber,
          startColumn: start + 1,
          endColumn: end + 1,
        },
      }),
    ),
  };
}

interface SpringPropertySuggestion {
  label: string;
  insertText: string;
  detail: string;
  documentation?: string;
  filterText: string;
  sortText: string;
  range: { startLineNumber: number; endLineNumber: number; startColumn: number; endColumn: number };
}
