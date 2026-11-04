/**
 * Projects native boolean context snapshots into truth tables compiled by Core.
 * No source parsing, expression evaluation, or host request occurs on keydown.
 */
import { invoke } from "@/platform/tauri-core";
import { logger } from "@/features/editor/utils/logger";
import type { Keybinding, KeymapContext } from "../types/keymaps.types";

export interface ParsedContext {
  keys: string[];
  values: boolean[];
}
interface ParseResult {
  parsed: ParsedContext | null;
  error: { code: string; byteOffset: number } | null;
}
interface PreparedContext {
  parsed?: ParsedContext;
  promise: Promise<void>;
}
const MAX_PREPARED_CONTEXTS = 256;
const MAX_IN_FLIGHT_CONTEXTS = 16;
const prepared = new Map<string, PreparedContext>();
let inFlight = 0;

export class KeymapContextError extends Error {
  constructor(
    readonly code: string,
    readonly byteOffset: number = 0,
  ) {
    super(code);
  }
}

async function compileContext(expression: string): Promise<ParsedContext> {
  if (inFlight >= MAX_IN_FLIGHT_CONTEXTS) throw new KeymapContextError("preparation_busy");
  inFlight++;
  try {
    const result = await invoke<ParseResult>("keymap.parseContext", { expression });
    if (result.error) throw new KeymapContextError(result.error.code, result.error.byteOffset);
    if (!result.parsed) throw new KeymapContextError("invalid_plan");
    return result.parsed;
  } finally {
    inFlight--;
  }
}

/** Validate an import privately, then publish its plans together if they fit. */
export async function prepareImportedContexts(bindings: Keybinding[]): Promise<void> {
  const expressions = new Set(bindings.map((binding) => binding.when).filter((value): value is string => !!value));
  if (new Set([...prepared.keys(), ...expressions]).size > MAX_PREPARED_CONTEXTS) {
    throw new KeymapContextError("too_many_conditions");
  }
  const staged = new Map<string, ParsedContext>();
  for (const expression of expressions) {
    const existing = prepared.get(expression);
    if (existing) {
      await existing.promise;
      if (existing.parsed) staged.set(expression, existing.parsed);
    } else {
      staged.set(expression, await compileContext(expression));
    }
  }
  // Other consumers can change the cache while the import is validating.
  if (new Set([...prepared.keys(), ...expressions]).size > MAX_PREPARED_CONTEXTS) {
    throw new KeymapContextError("too_many_conditions");
  }
  for (const [expression, parsed] of staged) {
    if (!prepared.has(expression)) prepared.set(expression, { parsed, promise: Promise.resolve() });
  }
}

/** Validate before publishing or persisting a binding; concurrent callers share one request. */
export async function prepareWhenClause(expression: string | undefined): Promise<void> {
  if (!expression) return;
  const existing = prepared.get(expression);
  if (existing) return existing.promise;
  if (prepared.size >= MAX_PREPARED_CONTEXTS) {
    throw new KeymapContextError("too_many_conditions");
  }
  const entry: PreparedContext = { promise: Promise.resolve() };
  prepared.set(expression, entry);
  entry.promise = compileContext(expression)
    .then((parsed) => {
      entry.parsed = parsed;
    })
    .catch((error) => {
      if (prepared.get(expression) === entry) prepared.delete(expression);
      throw error;
    });
  return entry.promise;
}

/** Registry/default/hydrated input is fail-closed, with diagnostics outside keydown. */
export async function prepareKeymapContexts(
  bindings: Keybinding[],
  signal?: AbortSignal,
): Promise<void> {
  const expressions = new Set(bindings.map((binding) => binding.when).filter(Boolean));
  for (const expression of prepared.keys()) {
    if (!expressions.has(expression)) prepared.delete(expression);
  }
  for (const expression of expressions) {
    if (signal?.aborted) return;
    try {
      await prepareWhenClause(expression);
    } catch (error) {
      logger.warn("Keymaps", "Context preparation failed", error);
    }
  }
}

/** Context keys are boolean. Missing keys project to false, as specified by Core. */
export function evaluateWhenClause(
  whenClause: string | undefined,
  context: Partial<KeymapContext>,
): boolean {
  if (!whenClause) return true;
  const table = prepared.get(whenClause)?.parsed;
  if (!table) return false;
  const index = table.keys.reduce(
    (index, key, bit) => index + (context[key] === true ? 2 ** bit : 0),
    0,
  );
  return table.values[index] === true;
}

/** The window's keyboard owner releases its cache together with its event listeners. */
export function releasePreparedContexts(): void {
  prepared.clear();
}
