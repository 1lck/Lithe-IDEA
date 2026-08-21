import type { FileIconSemanticKind } from "./file-icon-semantics";

export type JavaFileIconSemanticKind = Extract<
  FileIconSemanticKind,
  | "java.class"
  | "java.interface"
  | "java.enum"
  | "java.annotation"
  | "java.record"
  | "java.exception"
>;

function maskJavaCommentsAndLiterals(source: string): string {
  let output = "";
  let index = 0;
  let state: "code" | "line-comment" | "block-comment" | "string" | "char" | "text-block" = "code";

  const appendMasked = (value: string) => {
    output += value.replace(/[^\r\n]/g, " ");
  };

  while (index < source.length) {
    const nextTwo = source.slice(index, index + 2);
    const nextThree = source.slice(index, index + 3);
    const character = source[index] ?? "";

    if (state === "code") {
      if (nextTwo === "//") {
        appendMasked(nextTwo);
        index += 2;
        state = "line-comment";
        continue;
      }
      if (nextTwo === "/*") {
        appendMasked(nextTwo);
        index += 2;
        state = "block-comment";
        continue;
      }
      if (nextThree === '"""') {
        appendMasked(nextThree);
        index += 3;
        state = "text-block";
        continue;
      }
      if (character === '"') {
        appendMasked(character);
        index += 1;
        state = "string";
        continue;
      }
      if (character === "'") {
        appendMasked(character);
        index += 1;
        state = "char";
        continue;
      }

      output += character;
      index += 1;
      continue;
    }

    if (state === "line-comment") {
      appendMasked(character);
      index += 1;
      if (character === "\n") state = "code";
      continue;
    }

    if (state === "block-comment") {
      if (nextTwo === "*/") {
        appendMasked(nextTwo);
        index += 2;
        state = "code";
      } else {
        appendMasked(character);
        index += 1;
      }
      continue;
    }

    if (state === "text-block") {
      if (nextThree === '"""') {
        appendMasked(nextThree);
        index += 3;
        state = "code";
      } else {
        appendMasked(character);
        index += 1;
      }
      continue;
    }

    if (character === "\\") {
      appendMasked(source.slice(index, index + 2));
      index += Math.min(2, source.length - index);
      continue;
    }

    appendMasked(character);
    index += 1;
    if ((state === "string" && character === '"') || (state === "char" && character === "'")) {
      state = "code";
    }
  }

  return output;
}

function getJavaBaseName(fileName: string): string | null {
  const leafName = fileName.split(/[\\/]/).pop() ?? fileName;
  if (!leafName.toLowerCase().endsWith(".java")) return null;
  return leafName.slice(0, -".java".length);
}

function stripLeadingTypeParameters(declarationTail: string): string {
  let index = 0;
  while (/\s/.test(declarationTail[index] ?? "")) index += 1;
  if (declarationTail[index] !== "<") return declarationTail.slice(index);

  let depth = 0;
  for (; index < declarationTail.length; index += 1) {
    const character = declarationTail[index];
    if (character === "<") depth += 1;
    if (character === ">") {
      depth -= 1;
      if (depth === 0) return declarationTail.slice(index + 1);
    }
  }
  return "";
}

export function detectJavaFileIconSemanticKind(
  fileName: string,
  source: string,
): JavaFileIconSemanticKind | null {
  const baseName = getJavaBaseName(fileName);
  if (!baseName) return null;

  const maskedSource = maskJavaCommentsAndLiterals(source);
  const declarationPattern =
    /@interface\s+([A-Za-z_$][\w$]*)|\b(class|interface|enum|record)\s+([A-Za-z_$][\w$]*)/g;
  let braceDepth = 0;
  let scanIndex = 0;

  for (const match of maskedSource.matchAll(declarationPattern)) {
    const matchIndex = match.index ?? 0;
    while (scanIndex < matchIndex) {
      const character = maskedSource[scanIndex];
      if (character === "{") braceDepth += 1;
      if (character === "}") braceDepth = Math.max(0, braceDepth - 1);
      scanIndex += 1;
    }

    if (braceDepth !== 0) continue;

    const annotationName = match[1];
    const declarationKind = match[2];
    const declarationName = annotationName ?? match[3];
    if (declarationName !== baseName) continue;

    if (annotationName) return "java.annotation";
    if (declarationKind === "interface") return "java.interface";
    if (declarationKind === "enum") return "java.enum";
    if (declarationKind === "record") return "java.record";

    const declarationEnd = maskedSource.indexOf("{", matchIndex);
    const declarationTail = maskedSource.slice(
      matchIndex + match[0].length,
      declarationEnd === -1 ? maskedSource.length : declarationEnd,
    );
    if (
      /\bextends\s+(?:java\.lang\.)?(?:RuntimeException|Exception|Throwable|Error)\b/.test(
        stripLeadingTypeParameters(declarationTail),
      )
    ) {
      return "java.exception";
    }

    return "java.class";
  }

  return null;
}
