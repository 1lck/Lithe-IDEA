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

const TYPE_KEYWORDS = "class|interface|enum|record";
const MODIFIERS =
  "(?:(?:public|protected|private|abstract|final|sealed|non-sealed|static)\\s+)*";

const PUBLIC_TYPE_PATTERN = new RegExp(
  String.raw`(?:^|\n)\s*public\s+${MODIFIERS}(?:${TYPE_KEYWORDS})\s+([A-Za-z_$][\w$]*)\b`,
);

const ANY_TYPE_PATTERN = new RegExp(
  String.raw`(?:^|\n)\s*${MODIFIERS}(?:${TYPE_KEYWORDS})\s+([A-Za-z_$][\w$]*)\b`,
);

/**
 * Returns the primary Java type in `text`, preferring a `public` type so the
 * file name matches Java's one-public-type-per-file rule.
 */
export function parseJavaTypeClipboard(text: string): ParsedJavaClipboardClass | null {
  const content = text.replace(/^\uFEFF/, "");
  if (!content.trim()) return null;

  const publicMatch = content.match(PUBLIC_TYPE_PATTERN);
  if (publicMatch?.[1]) {
    return { typeName: publicMatch[1], content };
  }

  const anyMatch = content.match(ANY_TYPE_PATTERN);
  if (anyMatch?.[1]) {
    return { typeName: anyMatch[1], content };
  }

  return null;
}

/** Builds `Name.java`, then `Name copy.java`, `Name copy 2.java`, … */
export function nextJavaClassFileName(
  typeName: string,
  existingNames: ReadonlySet<string>,
): string {
  const base = `${typeName}.java`;
  if (!existingNames.has(base.toLowerCase())) return base;

  let suffix = 1;
  while (true) {
    const candidate =
      suffix === 1 ? `${typeName} copy.java` : `${typeName} copy ${suffix}.java`;
    if (!existingNames.has(candidate.toLowerCase())) return candidate;
    suffix += 1;
  }
}
