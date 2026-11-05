// Pure rules for plugin editor providers (API-25): how the host's answers,
// already validated and normalized by Core, become editor data. The host
// sends LSP shapes with zero-based positions; Monaco is one-based. Nothing
// here touches Monaco, so every rule is testable on its own.

import type { LspSemanticTokensResponse } from "./semantic-token-types";

/** A one-based Monaco range. */
export interface Span {
  startLineNumber: number;
  startColumn: number;
  endLineNumber: number;
  endColumn: number;
}

export interface HoverSection {
  value: string;
  isTrusted: false;
  supportHtml: false;
}

export interface FoldingSpan {
  start: number;
  end: number;
  kind?: "comment" | "imports" | "region";
}

export interface LensItem {
  id: string;
  range: Span;
  title: string;
}

export interface LinkItem {
  id: string;
  range: Span;
  tooltip?: string;
}

export interface SemanticLegend {
  tokenTypes: string[];
  tokenModifiers: string[];
}

const MARKDOWN_SPECIALS = /[\\`*_{}[\]()<>#+.!|~-]/g;

const isNonNegativeInteger = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;
const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;
const list = (value: unknown): unknown[] => Array.isArray(value) ? value : [];

/** An LSP range inside the document, as a one-based span; nothing for a malformed or foreign one. */
export function toSpan(value: unknown, lineCount: number): Span | undefined {
  if (!isRecord(value) || !isRecord(value.start) || !isRecord(value.end)) return undefined;
  const { line: startLine, character: startCharacter } = value.start;
  const { line: endLine, character: endCharacter } = value.end;
  if (!isNonNegativeInteger(startLine) || !isNonNegativeInteger(startCharacter) ||
      !isNonNegativeInteger(endLine) || !isNonNegativeInteger(endCharacter) ||
      endLine >= lineCount || startLine > endLine || (startLine === endLine && startCharacter > endCharacter)) return undefined;
  return { startLineNumber: startLine + 1, startColumn: startCharacter + 1, endLineNumber: endLine + 1, endColumn: endCharacter + 1 };
}

/** Hover sections in plugin order: markdown as is, plain text escaped so it renders as written. */
export function hoverSections(reply: unknown): HoverSection[] {
  const sections: HoverSection[] = [];
  for (const part of list(isRecord(reply) ? reply.contents : undefined)) {
    if (!isRecord(part) || typeof part.value !== "string" || part.value === "") continue;
    const value = part.kind === "plaintext" ? part.value.replace(MARKDOWN_SPECIALS, "\\$&") : part.value;
    sections.push({ value, isTrusted: false, supportHtml: false });
  }
  return sections;
}

/** Folding ranges inside the document; the host's `startLine` and `endLine` are zero-based. */
export function foldingSpans(reply: unknown, lineCount: number): FoldingSpan[] {
  const spans: FoldingSpan[] = [];
  for (const item of list(isRecord(reply) ? reply.ranges : undefined)) {
    if (!isRecord(item) || !isNonNegativeInteger(item.startLine) || !isNonNegativeInteger(item.endLine) ||
        item.endLine <= item.startLine || item.endLine >= lineCount) continue;
    const kind = item.kind === "comment" || item.kind === "imports" || item.kind === "region" ? item.kind : undefined;
    spans.push({ start: item.startLine + 1, end: item.endLine + 1, kind });
  }
  return spans;
}

/** Code lenses the page can ask the host to run: each has an opaque key, a span and a title. */
export function lensItems(reply: unknown, lineCount: number): { batch: string; lenses: LensItem[] } {
  const batch = isRecord(reply) && typeof reply.batch === "string" ? reply.batch : "";
  const lenses: LensItem[] = [];
  for (const item of batch ? list(isRecord(reply) ? reply.lenses : undefined) : []) {
    if (!isRecord(item) || typeof item.id !== "string" || typeof item.title !== "string") continue;
    const range = toSpan(item.range, lineCount);
    if (range) lenses.push({ id: item.id, range, title: item.title });
  }
  return { batch, lenses };
}

/** Document links the page can ask the host to open: opaque key, span and optional tooltip. */
export function linkItems(reply: unknown, lineCount: number): { batch: string; links: LinkItem[] } {
  const batch = isRecord(reply) && typeof reply.batch === "string" ? reply.batch : "";
  const links: LinkItem[] = [];
  for (const item of batch ? list(isRecord(reply) ? reply.links : undefined) : []) {
    if (!isRecord(item) || typeof item.id !== "string") continue;
    const range = toSpan(item.range, lineCount);
    if (range) links.push({ id: item.id, range, tooltip: typeof item.tooltip === "string" ? item.tooltip : undefined });
  }
  return { batch, links };
}

/**
 * The URL a drawn link carries: the batch is the host's list, the key one
 * entry of it. Both are opaque tokens the host generated (UUIDs), so the URL
 * survives Monaco parsing it; the host looks the real target up itself.
 */
export const LINK_SCHEME = "lithe-plugin-link";

export function linkUrl(batch: string, id: string): string {
  return `${LINK_SCHEME}:/${encodeURIComponent(batch)}/${encodeURIComponent(id)}`;
}

export function parseLinkUrl(value: string): { batch: string; id: string } | undefined {
  const match = new RegExp(`^${LINK_SCHEME}:/([^/]+)/([^/]+)$`).exec(value);
  if (!match) return undefined;
  try {
    return { batch: decodeURIComponent(match[1]), id: decodeURIComponent(match[2]) };
  } catch {
    return undefined;
  }
}

/**
 * Semantic token answers as one absolute token list. Registrations may use
 * different legends, so type and modifier names are merged into one legend
 * and every token is renumbered into it; the existing LSP encoder then maps
 * them to Monaco's legend, drops overlaps and orders them.
 */
export function mergeSemanticResponses(responses: unknown): LspSemanticTokensResponse {
  const merged: LspSemanticTokensResponse = { tokens: [], tokenTypes: [], tokenModifiers: [] };
  const indexOf = (names: string[], name: string) => {
    const found = names.indexOf(name);
    if (found >= 0) return found;
    names.push(name);
    return names.length - 1;
  };
  for (const response of list(responses)) {
    if (!isRecord(response) || !isRecord(response.legend) || !Array.isArray(response.data)) continue;
    const legend = response.legend as Partial<SemanticLegend>, data = response.data as unknown[];
    if (!Array.isArray(legend.tokenTypes) || !Array.isArray(legend.tokenModifiers) || data.length % 5 !== 0) continue;
    const typeMap = legend.tokenTypes.map(name => indexOf(merged.tokenTypes, String(name)));
    // A legend of more than 32 modifiers cannot be a bit set; the host already refuses it.
    const modifierMap = legend.tokenModifiers.slice(0, 32).map(name => indexOf(merged.tokenModifiers, String(name)));
    let line = 0, character = 0;
    for (let offset = 0; offset < data.length; offset += 5) {
      const [deltaLine, deltaStart, length, type, modifiers] = data.slice(offset, offset + 5);
      if (![deltaLine, deltaStart, length, type, modifiers].every(isNonNegativeInteger)) break;
      line += deltaLine as number;
      character = deltaLine === 0 ? character + (deltaStart as number) : (deltaStart as number);
      const tokenType = typeMap[type as number];
      if (tokenType === undefined) continue;
      let tokenModifiers = 0;
      modifierMap.forEach((target, source) => {
        if ((((modifiers as number) >>> source) & 1) === 1 && target < 32) tokenModifiers |= 1 << target;
      });
      merged.tokens.push({ line, startChar: character, length: length as number, tokenType, tokenModifiers: tokenModifiers >>> 0 });
    }
  }
  return merged;
}
