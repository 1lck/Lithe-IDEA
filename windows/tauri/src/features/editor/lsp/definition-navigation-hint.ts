import type { LspLocation } from "./lsp-client";

export interface DefinitionNavigationHint {
  sourceFilePath: string;
  sourceLine: number;
  sourceStartCharacter: number;
  sourceEndCharacter: number;
  locations: LspLocation[];
}

interface DefinitionSourcePosition {
  filePath: string;
  line: number;
  character: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function isPosition(value: unknown): value is { line: number; character: number } {
  return (
    isRecord(value) && isNonNegativeInteger(value.line) && isNonNegativeInteger(value.character)
  );
}

function isLocation(value: unknown): value is LspLocation {
  return (
    isRecord(value) &&
    typeof value.uri === "string" &&
    value.uri.length > 0 &&
    isRecord(value.range) &&
    isPosition(value.range.start) &&
    isPosition(value.range.end)
  );
}

function definitionNavigationHint(args: unknown): DefinitionNavigationHint | null {
  if (!isRecord(args) || !isRecord(args.definitionHint)) return null;
  const hint = args.definitionHint;
  if (
    typeof hint.sourceFilePath !== "string" ||
    hint.sourceFilePath.length === 0 ||
    !isNonNegativeInteger(hint.sourceLine) ||
    !isNonNegativeInteger(hint.sourceStartCharacter) ||
    !isNonNegativeInteger(hint.sourceEndCharacter) ||
    hint.sourceEndCharacter <= hint.sourceStartCharacter ||
    !Array.isArray(hint.locations) ||
    !hint.locations.every(isLocation)
  ) {
    return null;
  }
  return {
    sourceFilePath: hint.sourceFilePath,
    sourceLine: hint.sourceLine,
    sourceStartCharacter: hint.sourceStartCharacter,
    sourceEndCharacter: hint.sourceEndCharacter,
    locations: hint.locations,
  };
}

export function definitionLocationsFromCommandArgs(
  args: unknown,
  source: DefinitionSourcePosition,
): LspLocation[] | undefined {
  const hint = definitionNavigationHint(args);
  if (
    !hint ||
    hint.sourceFilePath !== source.filePath ||
    hint.sourceLine !== source.line ||
    source.character < hint.sourceStartCharacter ||
    source.character >= hint.sourceEndCharacter
  ) {
    return undefined;
  }
  return hint.locations;
}
