#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REGISTRY_PATH = path.join(SCRIPT_DIRECTORY, "worktree-resources.json");
const VERIFIER_PATH = path.join(SCRIPT_DIRECTORY, "verify-download-cache.mjs");
const PROCESS_TIMEOUT_MS = 300_000;
const INTEGRITY_MANIFEST = ".lithe-integrity.json";

function usage() {
  return [
    "Usage:",
    "  node scripts/reuse-worktree-resources.mjs --source <worktree> [--target <worktree>] [--resource <id> ...]",
    "  node scripts/reuse-worktree-resources.mjs --list",
    "",
    "The target defaults to the current worktree. All registered resources are reused unless --resource is provided.",
  ].join("\n");
}

function parseArguments(argv) {
  const options = { source: null, target: process.cwd(), resources: [], list: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === "--help" || option === "-h") {
      options.help = true;
      continue;
    }
    if (option === "--list") {
      options.list = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value) throw new Error(`${option} requires a value`);
    index += 1;
    if (option === "--source") options.source = value;
    else if (option === "--target") options.target = value;
    else if (option === "--resource") options.resources.push(value);
    else throw new Error(`Unknown option: ${option}`);
  }
  return options;
}

async function pathExists(candidate) {
  try {
    await fs.lstat(candidate);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function readRegistry() {
  const registry = JSON.parse(await fs.readFile(REGISTRY_PATH, "utf8"));
  if (registry.schemaVersion !== 1 || !Array.isArray(registry.resources)) {
    throw new Error(`Unsupported worktree resource registry: ${REGISTRY_PATH}`);
  }
  const identifiers = new Set();
  const validators = new Set(["cargo", "swiftpm", "bun", "jdtls", "jdk"]);
  for (const resource of registry.resources) {
    if (!resource?.id || identifiers.has(resource.id)) throw new Error(`Duplicate or missing resource id: ${resource?.id ?? "<missing>"}`);
    if (!validators.has(resource.validator)) throw new Error(`Unknown validator for ${resource.id}: ${resource.validator}`);
    const segments = String(resource.path).split(/[\\/]/);
    if (
      path.isAbsolute(resource.path) ||
      segments.length < 2 ||
      segments[0] !== ".artifacts" ||
      segments.slice(1).some((segment) => !segment || segment === "." || segment === "..")
    ) {
      throw new Error(`Resource ${resource.id} must stay inside .artifacts: ${resource.path}`);
    }
    identifiers.add(resource.id);
  }
  return registry.resources;
}

function runGit(worktree, argumentsList) {
  const result = spawnSync(
    "git",
    ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", worktree, ...argumentsList],
    { encoding: "utf8", timeout: PROCESS_TIMEOUT_MS },
  );
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || result.error || "git command failed").toString().trim());
  }
  return result.stdout.trim();
}

function pathKey(candidate) {
  const normalized = path.normalize(candidate);
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

async function resolveWorktree(candidate, label) {
  const resolved = await fs.realpath(path.resolve(candidate));
  const status = await fs.lstat(resolved);
  if (!status.isDirectory()) throw new Error(`${label} worktree is not a directory: ${resolved}`);
  const root = await fs.realpath(runGit(resolved, ["rev-parse", "--show-toplevel"]));
  if (root !== resolved) throw new Error(`${label} must name the worktree root: ${resolved}`);
  const commonDirectoryOutput = runGit(root, ["rev-parse", "--git-common-dir"]);
  const commonDirectory = await fs.realpath(path.resolve(root, commonDirectoryOutput));
  return { root, commonDirectory };
}

async function assertSafeResourcePath(root, relativePath, label) {
  let current = root;
  for (const segment of relativePath.split(/[\\/]/)) {
    current = path.join(current, segment);
    if (!(await pathExists(current))) continue;
    const status = await fs.lstat(current);
    if (status.isSymbolicLink()) throw new Error(`${label} contains a symbolic link: ${current}`);
  }
}

async function assertRealDirectory(candidate, label) {
  const status = await fs.lstat(candidate);
  if (status.isSymbolicLink() || !status.isDirectory()) {
    throw new Error(`${label} must be a real directory: ${candidate}`);
  }
}

async function requiredFile(root, relativePath, resourceID) {
  const candidate = path.join(root, relativePath);
  if (!(await pathExists(candidate))) throw new Error(`${resourceID} requires ${relativePath} in the target worktree`);
  return candidate;
}

async function validatorArguments(resource, cachePath, targetRoot) {
  if (resource.validator === "cargo") {
    const lockPaths = [];
    for (const relativePath of ["rust/Cargo.lock", "windows/tauri/src-tauri/Cargo.lock"]) {
      const candidate = path.join(targetRoot, relativePath);
      if (await pathExists(candidate)) lockPaths.push(candidate);
    }
    if (lockPaths.length === 0) throw new Error("cargo requires at least one Cargo.lock in the target worktree");
    return ["--cargo-cache", cachePath, ...lockPaths.flatMap((lockPath) => ["--cargo-lock", lockPath])];
  }
  if (resource.validator === "jdtls") {
    return ["--skip-cargo", "--jdtls-cache", cachePath, "--jdtls-manifest", await requiredFile(targetRoot, "third_party/jdtls/manifest.json", resource.id)];
  }
  if (resource.validator === "jdk") {
    return ["--skip-cargo", "--jdk-cache", cachePath, "--jdk-manifest", await requiredFile(targetRoot, "third_party/jdk/manifest.json", resource.id)];
  }
  if (resource.validator === "swiftpm") {
    const swiftVersionPath = await requiredFile(targetRoot, ".swift-version", resource.id);
    const swiftVersion = (await fs.readFile(swiftVersionPath, "utf8")).trim();
    return [
      "--skip-cargo",
      "--swiftpm-cache", cachePath,
      "--swiftpm-resolved", await requiredFile(targetRoot, "Package.resolved", resource.id),
      "--swift-version", swiftVersion,
    ];
  }
  if (resource.validator === "bun") {
    const packagePath = await requiredFile(targetRoot, "package.json", resource.id);
    const packageManifest = JSON.parse(await fs.readFile(packagePath, "utf8"));
    const match = String(packageManifest.packageManager ?? "").match(/^bun@(.+)$/);
    if (!match) throw new Error("bun requires package.json packageManager to pin Bun");
    return [
      "--skip-cargo",
      "--bun-version", match[1],
      "--bun-lock", await requiredFile(targetRoot, "bun.lock", resource.id),
      "--bun-cache", cachePath,
    ];
  }
  throw new Error(`Unsupported validator: ${resource.validator}`);
}

async function verifyResource(resource, cachePath, targetRoot) {
  const argumentsList = await validatorArguments(resource, cachePath, targetRoot);
  const result = spawnSync(process.execPath, [VERIFIER_PATH, ...argumentsList], {
    cwd: targetRoot,
    encoding: "utf8",
    env: { ...process.env, GITHUB_ACTIONS: "false" },
    maxBuffer: 64 * 1024 * 1024,
    timeout: PROCESS_TIMEOUT_MS,
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) {
    throw new Error(`Validation failed for ${resource.id}: ${result.error || `exit ${result.status}`}`);
  }
}

async function countPayloadFiles(root) {
  if (!(await pathExists(root))) return 0;
  let count = 0;
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(candidate);
      else if (entry.isFile() && entry.name !== INTEGRITY_MANIFEST) count += 1;
    }
  }
  return count;
}

async function publishDirectory(staging, destination, validatePublished) {
  const suffix = `${process.pid}-${randomUUID()}`;
  const backup = `${destination}.backup-${suffix}`;
  const destinationExists = await pathExists(destination);
  let committed = false;
  try {
    if (destinationExists) await fs.rename(destination, backup);
    await fs.rename(staging, destination);
    await validatePublished(destination);
    committed = true;
  } catch (error) {
    if (await pathExists(destination)) await fs.rm(destination, { force: true, recursive: true });
    if (await pathExists(backup)) {
      try {
        await fs.rename(backup, destination);
      } catch (restoreError) {
        throw new AggregateError([error, restoreError], `Could not publish or restore ${destination}`);
      }
    }
    throw error;
  } finally {
    if (committed) await fs.rm(backup, { force: true, recursive: true });
  }
}

async function reuseResource(resource, sourceRoot, targetRoot) {
  const source = path.join(sourceRoot, resource.path);
  const destination = path.join(targetRoot, resource.path);
  if (!(await pathExists(source))) {
    process.stdout.write(`Skipping ${resource.id}: source resource is absent.\n`);
    return;
  }
  await assertSafeResourcePath(sourceRoot, resource.path, `${resource.id} source`);
  await assertSafeResourcePath(targetRoot, resource.path, `${resource.id} target`);
  await assertRealDirectory(source, `${resource.id} source`);
  await fs.mkdir(path.dirname(destination), { recursive: true });
  const staging = `${destination}.staging-${process.pid}-${randomUUID()}`;
  try {
    await fs.cp(source, staging, { recursive: true, force: true, preserveTimestamps: true });
    await verifyResource(resource, staging, targetRoot);
    const sourceFiles = await countPayloadFiles(staging);
    if (sourceFiles === 0) {
      process.stdout.write(`Skipping ${resource.id}: no verified source files remain.\n`);
      return;
    }

    let targetFiles = 0;
    if (await pathExists(destination)) {
      await assertRealDirectory(destination, `${resource.id} target`);
      await verifyResource(resource, destination, targetRoot);
      targetFiles = await countPayloadFiles(destination);
    }
    if (targetFiles >= sourceFiles) {
      process.stdout.write(`Keeping ${resource.id}: target already has ${targetFiles} verified file(s).\n`);
      return;
    }

    let publishedFiles = 0;
    await publishDirectory(staging, destination, async (published) => {
      await verifyResource(resource, published, targetRoot);
      publishedFiles = await countPayloadFiles(published);
      if (publishedFiles !== sourceFiles) {
        throw new Error(`${resource.id} published ${publishedFiles} file(s), expected ${sourceFiles}`);
      }
    });
    process.stdout.write(`Reused ${resource.id}: published ${publishedFiles} verified file(s).\n`);
  } finally {
    await fs.rm(staging, { force: true, recursive: true });
  }
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const resources = await readRegistry();
  if (options.list) {
    for (const resource of resources) process.stdout.write(`${resource.id}\t${resource.path}\n`);
    return;
  }
  if (!options.source) throw new Error(`--source is required\n\n${usage()}`);

  const selected = options.resources.length > 0
    ? options.resources.map((identifier) => {
      const resource = resources.find((candidate) => candidate.id === identifier);
      if (!resource) throw new Error(`Unknown resource: ${identifier}`);
      return resource;
    })
    : resources;
  const source = await resolveWorktree(options.source, "Source");
  const target = await resolveWorktree(options.target, "Target");
  if (pathKey(source.root) === pathKey(target.root)) throw new Error("Source and target worktrees must be different");
  if (pathKey(source.commonDirectory) !== pathKey(target.commonDirectory)) {
    throw new Error("Source and target must be linked worktrees of the same Git repository");
  }

  const artifactRoot = path.join(target.root, ".artifacts");
  const lock = path.join(artifactRoot, ".reuse-worktree-resources.lock");
  await fs.mkdir(artifactRoot, { recursive: true });
  try {
    await fs.mkdir(lock);
  } catch (error) {
    if (error?.code === "EEXIST") throw new Error(`Another resource reuse operation owns ${lock}`);
    throw error;
  }
  try {
    for (const resource of selected) await reuseResource(resource, source.root, target.root);
  } finally {
    await fs.rm(lock, { force: true, recursive: true });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
