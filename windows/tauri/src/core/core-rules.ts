/**
 * Synchronous bridge to the pure rules in rust/lithe-core-rules, compiled to wasm.
 *
 * The same Rust source also backs the `lithe-core` JSON commands that macOS and the Tauri backend
 * use. The wasm copy exists only because a few rules run on synchronous hot paths (key events,
 * store `set()` calls) where an asynchronous Tauri `invoke` cannot be awaited.
 *
 * Chromium (WebView2) refuses to compile wasm modules larger than 4 KB synchronously on the main
 * thread, so the module is instantiated once, asynchronously, at startup. UI that depends on a
 * rule must not render before `initializeCoreRules()` resolves. After that every call is
 * synchronous. There is deliberately no TypeScript fallback: if loading fails, startup fails.
 *
 * Note: .agents/notes/implemented/architecture/2026-11-05-core-rules-wasm-sync-bridge.md
 */
import { createTranslator, DEFAULT_DISPLAY_LANGUAGE } from "@/i18n/locale";

/** Where the build (scripts/windows/prepare/prepare-core-rules-wasm.mjs) stages the module. */
export const CORE_RULES_WASM_URL = "/core-rules/lithe_core_rules.wasm";

interface RulesExports {
  memory: WebAssembly.Memory;
  lithe_rules_alloc(length: number): number;
  lithe_rules_dealloc(pointer: number, length: number): void;
  lithe_rules_execute(pointer: number, length: number): number;
  lithe_rules_result_len(): number;
}

/** Failure reported by a rule, using the same `code` strings as Core errors. */
export class CoreRuleError extends Error {
  readonly code: string;
  readonly details?: string;

  constructor(code: string, message: string, details?: string) {
    super(message);
    this.name = "CoreRuleError";
    this.code = code;
    this.details = details;
  }
}

type RuleResponse<TData> =
  | { id: string | null; ok: true; data: TData }
  | { id: string | null; ok: false; error: { code: string; message: string; details?: string } };

const encoder = new TextEncoder();
const decoder = new TextDecoder();
let exportsRef: RulesExports | null = null;
let loading: Promise<void> | null = null;

function requiredExports(instance: WebAssembly.Instance): RulesExports {
  const candidate = instance.exports as Partial<RulesExports>;
  if (
    !(candidate.memory instanceof WebAssembly.Memory) ||
    typeof candidate.lithe_rules_alloc !== "function" ||
    typeof candidate.lithe_rules_dealloc !== "function" ||
    typeof candidate.lithe_rules_execute !== "function" ||
    typeof candidate.lithe_rules_result_len !== "function"
  ) {
    throw new Error("The rules module does not export the expected C ABI");
  }
  return candidate as RulesExports;
}

async function readModuleBytes(
  source: BufferSource | Promise<BufferSource> | undefined,
): Promise<BufferSource> {
  if (source) return source;
  const response = await fetch(CORE_RULES_WASM_URL);
  if (!response.ok) {
    throw new Error(`Could not fetch ${CORE_RULES_WASM_URL}: HTTP ${response.status}`);
  }
  return response.arrayBuffer();
}

/**
 * Loads and instantiates the rules module. Call once before rendering UI that needs a rule.
 * Repeated calls share one load; a failed load can be retried by calling again.
 *
 * `source` lets tests supply the module bytes from disk instead of fetching them.
 */
export function initializeCoreRules(source?: BufferSource | Promise<BufferSource>): Promise<void> {
  if (exportsRef) return Promise.resolve();
  loading ??= (async () => {
    const bytes = await readModuleBytes(source);
    const { instance } = (await WebAssembly.instantiate(
      bytes,
      {},
    )) as unknown as WebAssembly.WebAssemblyInstantiatedSource;
    exportsRef = requiredExports(instance);
  })().catch((error: unknown) => {
    loading = null;
    throw error;
  });
  return loading;
}

/**
 * Drops the loaded module so the next `initializeCoreRules()` instantiates it again. Bun runs test
 * files in one process, so a test that wraps the instance must reset first. Tests only.
 */
export function resetCoreRulesForTests(): void {
  exportsRef = null;
  loading = null;
}

/** Whether `initializeCoreRules()` has completed successfully. */
export function isCoreRulesReady(): boolean {
  return exportsRef !== null;
}

/** User-facing text for a failed startup load; uses the shared i18n catalog. */
export function coreRulesInitFailureMessage(error: unknown): string {
  const detail = error instanceof Error ? error.message : String(error);
  return createTranslator(DEFAULT_DISPLAY_LANGUAGE)("coreRules.initFailed", { message: detail });
}

/**
 * Runs one rule synchronously and returns its `data`, or throws {@link CoreRuleError}.
 * `command` and `payload` follow the matching `lithe-core` command contract.
 */
export function executeCoreRuleSync<TData, TPayload = unknown>(
  command: string,
  payload: TPayload,
): TData {
  const wasm = exportsRef;
  if (!wasm) {
    throw new CoreRuleError(
      "not_supported",
      createTranslator(DEFAULT_DISPLAY_LANGUAGE)("coreRules.notReady"),
    );
  }
  const request = encoder.encode(JSON.stringify({ id: "core-rules", command, payload }));
  const requestPointer = wasm.lithe_rules_alloc(request.length);
  let responsePointer = 0;
  let responseLength = 0;
  try {
    // Growing memory detaches earlier views, so take a fresh view for each access.
    new Uint8Array(wasm.memory.buffer, requestPointer, request.length).set(request);
    responsePointer = wasm.lithe_rules_execute(requestPointer, request.length);
    responseLength = wasm.lithe_rules_result_len();
    const text = decoder.decode(new Uint8Array(wasm.memory.buffer, responsePointer, responseLength));
    const response = JSON.parse(text) as RuleResponse<TData>;
    if (!response.ok) {
      throw new CoreRuleError(response.error.code, response.error.message, response.error.details);
    }
    return response.data;
  } finally {
    wasm.lithe_rules_dealloc(requestPointer, request.length);
    if (responsePointer) wasm.lithe_rules_dealloc(responsePointer, responseLength);
  }
}
