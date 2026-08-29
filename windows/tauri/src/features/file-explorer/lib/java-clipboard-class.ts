/**
 * Detects an IDEA-style Java type declaration in clipboard text so pasting onto
 * a package/folder can create `TypeName.java` with that content.
 */

export interface ParsedJavaClipboardClass {
  /** Top-level type name used for the `.java` file name. */
  typeName: string;
  /** Clipboard text written into the new file unchanged. */
  content: string;
}

const TYPE_KEYWORDS = "@interface|class|interface|enum|record";
const MODIFIERS =
  "(?:(?:public|protected|private|abstract|final|sealed|non-sealed|static)\\s+)*";

const TYPE_AT_CURSOR = new RegExp(
  String.raw`^(public\s+)?${MODIFIERS}(?:${TYPE_KEYWORDS})\s+([A-Za-z_$][\w$]*)\b`,
);

function isIdentifierChar(character: string): boolean {
  return /[A-Za-z0-9_$]/.test(character);
}

function skipLineComment(source: string, index: number): number {
  const newline = source.indexOf("\n", index);
  return newline === -1 ? source.length : newline + 1;
}

function skipBlockComment(source: string, index: number): number {
  const end = source.indexOf("*/", index + 2);
  return end === -1 ? source.length : end + 2;
}

function skipQuoted(source: string, index: number, quote: string): number {
  let cursor = index + 1;
  while (cursor < source.length) {
    if (source[cursor] === "\\") {
      cursor += 2;
      continue;
    }
    if (source[cursor] === quote) return cursor + 1;
    cursor += 1;
  }
  return source.length;
}

function skipTextBlock(source: string, index: number): number {
  const end = source.indexOf('"""', index + 3);
  return end === -1 ? source.length : end + 3;
}

/**
 * Walks the source and records type declarations that sit outside comments
 * and strings at brace depth 0, so nested and commented types cannot win.
 */
function scanTopLevelJavaTypes(source: string): { name: string; isPublic: boolean }[] {
  const types: { name: string; isPublic: boolean }[] = [];
  let index = 0;
  let depth = 0;

  while (index < source.length) {
    if (source.startsWith("//", index)) {
      index = skipLineComment(source, index);
      continue;
    }
    if (source.startsWith("/*", index)) {
      index = skipBlockComment(source, index);
      continue;
    }
    if (source.startsWith('"""', index)) {
      index = skipTextBlock(source, index);
      continue;
    }
    const current = source[index];
    if (current === '"' || current === "'") {
      index = skipQuoted(source, index, current);
      continue;
    }

    if (depth === 0) {
      const atTokenStart = index === 0 || !isIdentifierChar(source[index - 1] ?? "");
      if (atTokenStart) {
        const match = source.slice(index).match(TYPE_AT_CURSOR);
        if (match?.[2]) {
          types.push({ name: match[2], isPublic: Boolean(match[1]) });
          index += match[0].length;
          continue;
        }
      }
    }

    if (current === "{") depth += 1;
    else if (current === "}" && depth > 0) depth -= 1;
    index += 1;
  }

  return types;
}

/**
 * Returns the primary Java type in `text`, preferring a `public` type so the
 * file name matches Java's one-public-type-per-file rule.
 */
export function parseJavaTypeClipboard(text: string): ParsedJavaClipboardClass | null {
  const content = text.replace(/^\uFEFF/, "");
  if (!content.trim()) return null;

  const types = scanTopLevelJavaTypes(content);
  const publicType = types.find((type) => type.isPublic);
  const chosen = publicType ?? types[0];
  if (!chosen) return null;
  return { typeName: chosen.name, content };
}

export function javaTypeFileName(typeName: string): string {
  return `${typeName}.java`;
}
