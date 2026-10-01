#!/usr/bin/env node
// Build-time only: packaged helpers remain immutable at runtime.
import { spawnSync } from "node:child_process";
import { mkdirSync, copyFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "win32") throw new Error("The Windows MCP helper must be built on Windows");
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const target = process.env.TAURI_ENV_TARGET_TRIPLE || process.env.CARGO_BUILD_TARGET || "x86_64-pc-windows-msvc";
if (!["x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"].includes(target)) throw new Error(`Unsupported helper target: ${target}`);
const targetDirectory = path.join(root, "rust/target/windows-ide-mcp");
const result = spawnSync("cargo", ["build", "--locked", "--release", "--manifest-path", path.join(root,"rust/Cargo.toml"), "--target", target, "--target-dir", targetDirectory, "-p", "lithe-ide-host", "--features", "mcp", "--bin", "lithe-mcp"], {stdio:"inherit",timeout:1_200_000});
if (result.error || result.status !== 0) throw result.error || new Error("Could not build the Windows IDE MCP helper");
const destination = path.join(root,"windows/tauri/src-tauri/helpers");
mkdirSync(destination,{recursive:true});
copyFileSync(path.join(targetDirectory,target,"release/lithe-mcp.exe"),path.join(destination,"lithe-mcp.exe"));
