#!/usr/bin/env node
// Build-time only: compiles rust/lithe-core-rules to wasm32 and stages it for the Windows frontend.
// The module is a read-only packaged input served from the app's frontend assets; nothing at
// runtime writes it, so installed bundles, code signatures and Sparkle delta baselines are unchanged.
// Usage: node scripts/windows/prepare/prepare-core-rules-wasm.mjs [--check]
//   --check  verify that the staged module exists and is non-empty without building.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const WASM_TARGET = "wasm32-unknown-unknown";
const BUILT_NAME = "lithe_core_rules.wasm";
// Served at /core-rules/lithe_core_rules.wasm, next to the other wasm assets under public/.
export const STAGED_WASM = path.join(ROOT, "windows/tauri/public/core-rules", BUILT_NAME);

function run(command, args, options = {}) {
  return spawnSync(command, args, { encoding: "utf8", timeout: 1_200_000, ...options });
}

// Prefer rustup's cargo so a Homebrew or system cargo that lacks the wasm target cannot shadow it.
function resolveCargo() {
  if (process.env.CARGO) return process.env.CARGO;
  const which = run("rustup", ["which", "cargo"], { timeout: 30_000 });
  return which.status === 0 && which.stdout.trim() ? which.stdout.trim() : "cargo";
}

function ensureWasmTarget(cargo) {
  const rustc = path.join(path.dirname(cargo), process.platform === "win32" ? "rustc.exe" : "rustc");
  const sysroot = run(existsSync(rustc) ? rustc : "rustc", ["--print", "sysroot"], { timeout: 30_000 });
  const root = sysroot.status === 0 ? sysroot.stdout.trim() : "";
  if (!root || !existsSync(path.join(root, "lib/rustlib", WASM_TARGET))) {
    throw new Error(`The ${WASM_TARGET} Rust target is missing. Run: rustup target add ${WASM_TARGET}`);
  }
}

function verifyStaged() {
  if (!existsSync(STAGED_WASM) || statSync(STAGED_WASM).size === 0) {
    throw new Error(`Missing ${path.relative(ROOT, STAGED_WASM)}. Run: node scripts/windows/prepare/prepare-core-rules-wasm.mjs`);
  }
}

function build() {
  const cargo = resolveCargo();
  ensureWasmTarget(cargo);
  const cargoEnv = { ...process.env, PATH: `${path.dirname(cargo)}${path.delimiter}${process.env.PATH ?? ""}` };
  const manifest = path.join(ROOT, "rust/Cargo.toml");
  const result = run(cargo, ["build", "--locked", "--release", "--manifest-path", manifest, "--target", WASM_TARGET, "-p", "lithe-core-rules"], { stdio: "inherit", env: cargoEnv });
  if (result.error || result.status !== 0) throw result.error || new Error("Could not build lithe-core-rules for wasm32");
  const targetRoot = process.env.CARGO_TARGET_DIR ? path.resolve(process.env.CARGO_TARGET_DIR) : path.join(ROOT, "rust/target");
  const built = path.join(targetRoot, WASM_TARGET, "release", BUILT_NAME);
  if (!existsSync(built)) throw new Error(`Cargo did not produce ${built}`);
  const bytes = readFileSync(built);
  mkdirSync(path.dirname(STAGED_WASM), { recursive: true });
  // Keep the file untouched when identical so dev servers and file watchers stay quiet.
  if (!existsSync(STAGED_WASM) || !readFileSync(STAGED_WASM).equals(bytes)) copyFileSync(built, STAGED_WASM);
  const digest = createHash("sha256").update(bytes).digest("hex").slice(0, 16);
  console.log(`lithe-core-rules wasm: ${bytes.length} bytes, sha256 ${digest}, staged at ${path.relative(ROOT, STAGED_WASM)}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.includes("--check")) verifyStaged();
  else build();
}
