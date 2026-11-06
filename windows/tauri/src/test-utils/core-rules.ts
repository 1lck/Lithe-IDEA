import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { initializeCoreRules } from "@/core/core-rules";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const STAGED_WASM = path.join(ROOT, "windows/tauri/public/core-rules/lithe_core_rules.wasm");
const PREPARE_SCRIPT = path.join(ROOT, "scripts/windows/prepare/prepare-core-rules-wasm.mjs");
// A cold cargo build of the tiny rules crate takes seconds; the bound only guards against a hang.
const BUILD_TIMEOUT_MS = 300_000;

function newestSourceTime(directory: string): number {
  return readdirSync(directory, { withFileTypes: true }).reduce((newest, entry) => {
    const full = path.join(directory, entry.name);
    const time = entry.isDirectory() ? newestSourceTime(full) : statSync(full).mtimeMs;
    return Math.max(newest, time);
  }, 0);
}

function stagedModuleIsCurrent(): boolean {
  if (!existsSync(STAGED_WASM)) return false;
  const rulesRoot = path.join(ROOT, "rust/lithe-core-rules");
  const sources = Math.max(newestSourceTime(path.join(rulesRoot, "src")), statSync(path.join(rulesRoot, "Cargo.toml")).mtimeMs);
  return statSync(STAGED_WASM).mtimeMs >= sources;
}

/**
 * Loads the real wasm build of lithe-core-rules for a test. The module is the same artifact the
 * app ships. When it is missing or older than the Rust sources, this builds it first through the
 * production script, which needs rustup with the wasm32-unknown-unknown target.
 */
export async function loadCoreRulesForTests(): Promise<void> {
  if (!stagedModuleIsCurrent()) {
    const build = spawnSync("node", [PREPARE_SCRIPT], {
      encoding: "utf8",
      timeout: BUILD_TIMEOUT_MS,
    });
    if (build.status !== 0) {
      throw new Error(`Could not build the lithe-core-rules wasm module:\n${build.stdout}\n${build.stderr}`);
    }
  }
  await initializeCoreRules(readFileSync(STAGED_WASM));
}
