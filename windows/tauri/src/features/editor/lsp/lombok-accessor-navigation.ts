import { executeCore } from "@/core/lithe-core-client";
import { readFileContent } from "@/features/file-system/controllers/file-operations";
import { joinPath, normalizePath, pathStartsWithRoot } from "@/utils/path-helpers";
import type { LspLocation } from "./lsp-client";

interface JavaSourceDefinition {
  line: number;
  utf16Column: number;
}

interface LombokAccessorTarget {
  declarationName: string;
  fieldName: string;
  kind: "getter" | "boolean-getter" | "setter";
}

interface LombokNavigationDependencies {
  listWorkspaceFiles: (root: string) => Promise<string[]>;
  readSource: (filePath: string) => Promise<string>;
  findSourceDefinition: (
    source: string,
    declarationName: string,
    memberName?: string,
  ) => Promise<JavaSourceDefinition | null>;
}

interface ResolveLombokAccessorDefinitionOptions {
  source: string;
  sourceFilePath: string;
  workspaceRoot: string;
  line: number;
  character: number;
}

function coreData<T>(response: Awaited<ReturnType<typeof executeCore<T>>>): T {
  if (response.ok) return response.data;
  throw new Error(response.error.message);
}

function javaBeansFieldName(propertyName: string): string {
  if (propertyName.length > 1 && /[A-Z]/.test(propertyName[0]) && /[A-Z]/.test(propertyName[1])) {
    return propertyName;
  }
  return `${propertyName[0].toLowerCase()}${propertyName.slice(1)}`;
}

function maskJavaCommentsAndStrings(source: string): string {
  let masked = "";
  let state: "code" | "line-comment" | "block-comment" | "string" | "character" = "code";
  let escaped = false;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const nextCharacter = source[index + 1];
    if (character === "\r" || character === "\n") {
      masked += character;
      if (state === "line-comment") state = "code";
      continue;
    }

    if (state === "code") {
      if (character === "/" && nextCharacter === "/") {
        masked += "  ";
        index += 1;
        state = "line-comment";
      } else if (character === "/" && nextCharacter === "*") {
        masked += "  ";
        index += 1;
        state = "block-comment";
      } else if (character === '"') {
        masked += " ";
        state = "string";
        escaped = false;
      } else if (character === "'") {
        masked += " ";
        state = "character";
        escaped = false;
      } else {
        masked += character;
      }
      continue;
    }

    if (state === "block-comment" && character === "*" && nextCharacter === "/") {
      masked += "  ";
      index += 1;
      state = "code";
      continue;
    }

    if (state === "string" || state === "character") {
      const delimiter = state === "string" ? '"' : "'";
      if (!escaped && character === delimiter) state = "code";
      escaped = !escaped && character === "\\";
    }
    masked += " ";
  }

  return masked;
}

function openBraceStackAt(source: string, endOffset: number): number[] {
  const stack: number[] = [];
  for (let index = 0; index < endOffset; index += 1) {
    if (source[index] === "{") stack.push(index);
    if (source[index] === "}") stack.pop();
  }
  return stack;
}

function isScopePrefix(candidateScope: number[], cursorScope: number[]): boolean {
  return candidateScope.every((braceOffset, index) => cursorScope[index] === braceOffset);
}

function declaredReceiverType(sourcePrefix: string, receiverName: string): string | null {
  const escapedReceiver = receiverName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const declaration = new RegExp(
    `(?<![A-Za-z0-9_$.])([A-Z][A-Za-z0-9_$]*)\\s+${escapedReceiver}\\b\\s*(=|;|,|\\)|:)`,
    "g",
  );
  const cursorScope = openBraceStackAt(sourcePrefix, sourcePrefix.length);
  let match: RegExpExecArray | null;
  let declarationName: string | null = null;
  while ((match = declaration.exec(sourcePrefix))) {
    const delimiter = match[2];
    const candidateScope = openBraceStackAt(sourcePrefix, match.index);
    let visible = isScopePrefix(candidateScope, cursorScope);

    if (delimiter === "," || delimiter === ")") {
      const nextBrace = sourcePrefix.indexOf("{", declaration.lastIndex);
      const nextSemicolon = sourcePrefix.indexOf(";", declaration.lastIndex);
      visible =
        nextBrace >= 0 &&
        cursorScope.includes(nextBrace) &&
        (nextSemicolon < 0 || nextBrace < nextSemicolon);
    }

    if (visible) declarationName = match[1];
  }
  return declarationName;
}

export function lombokAccessorTargetAtPosition(
  source: string,
  line: number,
  character: number,
): LombokAccessorTarget | null {
  const maskedLines = maskJavaCommentsAndStrings(source).split(/\r?\n/);
  const lineText = maskedLines[line];
  if (!lineText || character < 0) return null;

  const methodReference = /\b([A-Z][A-Za-z0-9_$]*)\s*::\s*((get|set|is)([A-Z][A-Za-z0-9_$]*))/g;
  let match: RegExpExecArray | null;
  while ((match = methodReference.exec(lineText))) {
    const accessorStart = match.index + match[0].lastIndexOf(match[2]);
    const accessorEnd = accessorStart + match[2].length;
    if (character < accessorStart || character > accessorEnd) continue;
    const prefix = match[3];
    return {
      declarationName: match[1],
      fieldName: javaBeansFieldName(match[4]),
      kind: prefix === "set" ? "setter" : prefix === "is" ? "boolean-getter" : "getter",
    };
  }

  const instanceAccessor =
    /(?<![A-Za-z0-9_$.])([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*((get|set|is)([A-Z][A-Za-z0-9_$]*))\s*\(/g;
  while ((match = instanceAccessor.exec(lineText))) {
    const accessorStart = match.index + match[0].lastIndexOf(match[2]);
    const accessorEnd = accessorStart + match[2].length;
    if (character < accessorStart || character > accessorEnd) continue;

    const sourcePrefix = [...maskedLines.slice(0, line), lineText.slice(0, match.index)].join("\n");
    const declarationName = declaredReceiverType(sourcePrefix, match[1]);
    if (!declarationName) return null;

    const prefix = match[3];
    return {
      declarationName,
      fieldName: javaBeansFieldName(match[4]),
      kind: prefix === "set" ? "setter" : prefix === "is" ? "boolean-getter" : "getter",
    };
  }

  return null;
}

function importedTypeName(source: string, declarationName: string): string | null {
  const escapedName = declarationName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const explicitImport = new RegExp(
    `^\\s*import\\s+([A-Za-z_$][A-Za-z0-9_$.]*\\.${escapedName})\\s*;`,
    "m",
  ).exec(source)?.[1];
  if (explicitImport) return explicitImport;

  const packageName = /^\s*package\s+([A-Za-z_$][A-Za-z0-9_$.]*)\s*;/m.exec(source)?.[1];
  return packageName ? `${packageName}.${declarationName}` : declarationName;
}

function selectTypeSourcePath(
  source: string,
  declarationName: string,
  workspaceFiles: string[],
): string | null {
  const expectedName = `${declarationName}.java`;
  const candidates = workspaceFiles
    .map(normalizePath)
    .filter((path) => path.split("/").pop() === expectedName)
    .sort((left, right) => left.localeCompare(right));
  if (candidates.length === 0) return null;

  const qualifiedName = importedTypeName(source, declarationName);
  if (!qualifiedName) return null;
  const expectedSuffix = `${qualifiedName.replace(/\./g, "/")}.java`;
  const exactMatches = candidates.filter((path) => path.endsWith(expectedSuffix));
  return exactMatches.length === 1 ? exactMatches[0] : null;
}

function annotationPrefix(source: string, definition: JavaSourceDefinition): string {
  const lines = source.split(/\r?\n/);
  const declarationLine = lines[definition.line] ?? "";
  const precedingAnnotations: string[] = [];
  for (let index = definition.line - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (!/^(?:@[A-Za-z_$][A-Za-z0-9_$.]*(?:\s*\([^)]*\))?\s*)+$/.test(line.trim())) break;
    precedingAnnotations.unshift(line);
  }
  return [...precedingAnnotations, declarationLine.slice(0, definition.utf16Column)].join("\n");
}

function hasLombokAnnotation(source: string, prefix: string, annotation: string): boolean {
  if (new RegExp(`@lombok\\.${annotation}\\b`).test(prefix)) return true;
  if (!new RegExp(`@${annotation}\\b`).test(prefix)) return false;
  return new RegExp(`^\\s*import\\s+lombok\\.(?:${annotation}|\\*)\\s*;`, "m").test(source);
}

function hasLombokAccessor(
  source: string,
  target: LombokAccessorTarget,
  typeDefinition: JavaSourceDefinition,
  fieldDefinition: JavaSourceDefinition,
): boolean {
  const fieldPrefix = annotationPrefix(source, fieldDefinition);
  if (target.kind === "setter" && /\bfinal\b/.test(fieldPrefix)) return false;
  if (target.kind === "boolean-getter" && !/\bboolean\s*$/.test(fieldPrefix)) return false;

  const annotation = target.kind === "setter" ? "Setter" : "Getter";
  const typePrefix = annotationPrefix(source, typeDefinition);
  return (
    hasLombokAnnotation(source, typePrefix, "Data") ||
    hasLombokAnnotation(source, typePrefix, annotation) ||
    hasLombokAnnotation(source, fieldPrefix, annotation)
  );
}

const defaultDependencies: LombokNavigationDependencies = {
  async listWorkspaceFiles(root) {
    const response = await executeCore<{ files: string[] }>({
      id: crypto.randomUUID(),
      command: "workspace.snapshot",
      payload: { root },
    });
    return coreData(response).files;
  },
  readSource: readFileContent,
  async findSourceDefinition(source, declarationName, memberName) {
    const response = await executeCore<JavaSourceDefinition | null>({
      id: crypto.randomUUID(),
      command: "java.sourceDefinition",
      payload: { source, declarationName, memberName },
    });
    return coreData(response);
  },
};

export async function resolveLombokAccessorDefinition(
  options: ResolveLombokAccessorDefinitionOptions,
  dependencies: LombokNavigationDependencies = defaultDependencies,
): Promise<LspLocation | null> {
  if (!pathStartsWithRoot(options.sourceFilePath, options.workspaceRoot)) return null;
  const target = lombokAccessorTargetAtPosition(options.source, options.line, options.character);
  if (!target) return null;

  const workspaceFiles = await dependencies.listWorkspaceFiles(options.workspaceRoot);
  const relativePath = selectTypeSourcePath(options.source, target.declarationName, workspaceFiles);
  if (!relativePath) return null;

  const filePath = normalizePath(joinPath(options.workspaceRoot, relativePath));
  const targetSource = await dependencies.readSource(filePath);
  if (!/@(?:lombok\.)?(?:Data|Getter|Setter)\b/.test(targetSource)) return null;
  const definition = await dependencies.findSourceDefinition(
    targetSource,
    target.declarationName,
    target.fieldName,
  );
  if (!definition) return null;
  const typeDefinition = await dependencies.findSourceDefinition(
    targetSource,
    target.declarationName,
  );
  if (!typeDefinition || !hasLombokAccessor(targetSource, target, typeDefinition, definition)) {
    return null;
  }

  const position = { line: definition.line, character: definition.utf16Column };
  return {
    uri: filePath,
    filePath,
    range: { start: position, end: position },
  };
}
