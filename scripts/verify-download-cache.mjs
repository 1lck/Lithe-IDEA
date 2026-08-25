#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createReadStream, promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "..");

function workflowEscape(value) {
  return String(value).replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
}

function warn(title, message) {
  if (process.env.GITHUB_ACTIONS === "true") {
    process.stdout.write(`::warning title=${workflowEscape(title)}::${workflowEscape(message)}\n`);
  } else {
    process.stderr.write(`warning: ${title}: ${message}\n`);
  }
}

function parseArguments(argv) {
  const options = {
    cargoCache: path.join(REPOSITORY_ROOT, ".artifacts", "cargo-home", "registry", "cache"),
    cargoLocks: [],
    skipCargo: false,
    jdtlsCache: null,
    jdtlsManifest: null,
    jdkCache: null,
    jdkManifest: null,
    swiftpmCache: null,
    swiftpmResolved: null,
    swiftVersion: null,
    writeSwiftpmManifest: false,
    bunVersion: null,
    bunLock: null,
    bunCache: null,
    writeBunManifest: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === "--write-bun-manifest") {
      options.writeBunManifest = true;
      continue;
    }
    if (option === "--write-swiftpm-manifest") {
      options.writeSwiftpmManifest = true;
      continue;
    }
    if (option === "--skip-cargo") {
      options.skipCargo = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value) throw new Error(`${option} requires a value`);
    index += 1;
    if (option === "--cargo-cache") options.cargoCache = value;
    else if (option === "--cargo-lock") options.cargoLocks.push(value);
    else if (option === "--jdtls-cache") options.jdtlsCache = value;
    else if (option === "--jdtls-manifest") options.jdtlsManifest = value;
    else if (option === "--jdk-cache") options.jdkCache = value;
    else if (option === "--jdk-manifest") options.jdkManifest = value;
    else if (option === "--swiftpm-cache") options.swiftpmCache = value;
    else if (option === "--swiftpm-resolved") options.swiftpmResolved = value;
    else if (option === "--swift-version") options.swiftVersion = value;
    else if (option === "--bun-version") options.bunVersion = value;
    else if (option === "--bun-lock") options.bunLock = value;
    else if (option === "--bun-cache") options.bunCache = value;
    else throw new Error(`Unknown option: ${option}`);
  }

  if (options.cargoLocks.length === 0) {
    options.cargoLocks.push(
      path.join(REPOSITORY_ROOT, "rust", "Cargo.lock"),
      path.join(REPOSITORY_ROOT, "windows", "tauri", "src-tauri", "Cargo.lock"),
    );
  }
  return options;
}

async function exists(candidate) {
  try {
    await fs.lstat(candidate);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function sha256(filePath) {
  return await new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(filePath);
    stream.on("error", reject);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

function parseTomlString(packageBlock, field) {
  const match = packageBlock.match(new RegExp(`^${field} = ("(?:\\\\.|[^"\\\\])*")$`, "m"));
  return match ? JSON.parse(match[1]) : null;
}

async function expectedCargoArchives(lockPaths) {
  const expected = new Map();
  for (const lockPath of lockPaths) {
    const lock = await fs.readFile(lockPath, "utf8");
    for (const packageBlock of lock.split(/(?=^\[\[package\]\]$)/m)) {
      if (!packageBlock.startsWith("[[package]]")) continue;
      const name = parseTomlString(packageBlock, "name");
      const version = parseTomlString(packageBlock, "version");
      const checksum = parseTomlString(packageBlock, "checksum");
      if (!name || !version || !checksum) continue;
      const archiveName = `${name}-${version}.crate`;
      const existing = expected.get(archiveName);
      if (existing && existing !== checksum) {
        throw new Error(`Cargo locks disagree about the checksum for ${archiveName}`);
      }
      expected.set(archiveName, checksum.toLowerCase());
    }
  }
  return expected;
}

async function collectFiles(root) {
  if (!(await exists(root))) return [];
  const rootStatus = await fs.lstat(root);
  if (rootStatus.isSymbolicLink() || !rootStatus.isDirectory()) {
    warn("Unsafe cache root removed", `Expected a real directory but found an unsafe entry: ${root}`);
    await fs.rm(root, { force: true, recursive: true });
    await fs.mkdir(root, { recursive: true });
    return [];
  }
  const files = [];
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        warn("Unsafe cache entry removed", `Removed symbolic link from download cache: ${candidate}`);
        await fs.rm(candidate, { force: true, recursive: true });
      } else if (entry.isDirectory()) {
        pending.push(candidate);
      } else if (entry.isFile()) {
        files.push(candidate);
      } else {
        warn("Unsafe cache entry removed", `Removed unsupported filesystem entry: ${candidate}`);
        await fs.rm(candidate, { force: true, recursive: true });
      }
    }
  }
  return files;
}

async function verifyCargoCache(cacheRoot, lockPaths) {
  const expected = await expectedCargoArchives(lockPaths);
  let verified = 0;
  let removed = 0;
  for (const archive of await collectFiles(cacheRoot)) {
    const archiveName = path.basename(archive);
    const expectedHash = expected.get(archiveName);
    const actualHash = archiveName.endsWith(".crate") ? await sha256(archive) : null;
    if (!expectedHash || actualHash !== expectedHash) {
      const reason = expectedHash ? "SHA-256 mismatch" : "not referenced by the current Cargo locks";
      warn("Cargo cache entry rejected", `${archiveName}: ${reason}; Cargo will download it normally.`);
      await fs.rm(archive, { force: true });
      removed += 1;
    } else {
      verified += 1;
    }
  }
  process.stdout.write(`Cargo download cache verified: ${verified} archive(s), ${removed} rejected.\n`);
}

function safeVersion(value) {
  return String(value).replaceAll(/[^A-Za-z0-9._-]/g, "_");
}

async function verifyJdtlsCache(cacheRoot, manifestPath) {
  if (!cacheRoot || !manifestPath) return;
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const expected = new Map([
    [`jdtls-${safeVersion(manifest.version)}-${manifest.archiveSHA256.toLowerCase()}.tar.gz`, manifest.archiveSHA256],
    [`EPL-2.0-${manifest.licenseSHA256.toLowerCase()}.txt`, manifest.licenseSHA256],
    [`lombok-${safeVersion(manifest.lombokVersion)}-${manifest.lombokSHA256.toLowerCase()}.jar`, manifest.lombokSHA256],
    [`lombok-MIT-${safeVersion(manifest.lombokVersion)}-${manifest.lombokLicenseSHA256.toLowerCase()}.txt`, manifest.lombokLicenseSHA256],
  ]);
  let verified = 0;
  let removed = 0;
  for (const artifact of await collectFiles(cacheRoot)) {
    const artifactName = path.basename(artifact);
    const expectedHash = expected.get(artifactName)?.toLowerCase();
    const actualHash = expectedHash ? await sha256(artifact) : null;
    if (!expectedHash || actualHash !== expectedHash) {
      const reason = expectedHash ? "SHA-256 mismatch" : "not referenced by the JDTLS manifest";
      warn("JDTLS cache entry rejected", `${artifactName}: ${reason}; it will be downloaded normally.`);
      await fs.rm(artifact, { force: true });
      removed += 1;
    } else {
      verified += 1;
    }
  }
  process.stdout.write(`JDTLS download cache verified: ${verified} artifact(s), ${removed} rejected.\n`);
}

async function verifyJdkCache(cacheRoot, manifestPath) {
  if (!cacheRoot || !manifestPath) return;
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const expected = new Map(
    Object.entries(manifest.platforms ?? {})
      .map(([platform, entry]) => [
        `jdk-${safeVersion(manifest.version)}-${platform}-${entry.sha256.toLowerCase()}${platform.startsWith("windows-") ? ".zip" : ".tar.gz"}`,
        entry.sha256.toLowerCase(),
      ]),
  );
  let verified = 0;
  let removed = 0;
  for (const artifact of await collectFiles(cacheRoot)) {
    const artifactName = path.basename(artifact);
    const expectedHash = expected.get(artifactName);
    const actualHash = expectedHash ? await sha256(artifact) : null;
    if (!expectedHash || actualHash !== expectedHash) {
      const reason = expectedHash ? "SHA-256 mismatch" : "not referenced by the JDK manifest";
      warn("JDK cache entry rejected", `${artifactName}: ${reason}; it will be downloaded normally.`);
      await fs.rm(artifact, { force: true });
      removed += 1;
    } else {
      verified += 1;
    }
  }
  process.stdout.write(`JDK download cache verified: ${verified} artifact(s), ${removed} rejected.\n`);
}

function runGit(repository, argumentList) {
  const result = spawnSync(
    "git",
    ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", repository, ...argumentList],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || result.error || "git command failed").toString().trim());
  }
  return result.stdout.trim();
}

function normalizeRepositoryURL(value) {
  return String(value).trim().replace(/\.git\/?$/i, "").replace(/\/$/, "").toLowerCase();
}

async function expectedSwiftRepositories(resolvedPath) {
  const resolved = JSON.parse(await fs.readFile(resolvedPath, "utf8"));
  const expected = new Map();
  for (const pin of resolved.pins ?? []) {
    if (pin.kind !== "remoteSourceControl" || !pin.location || !pin.state?.revision) continue;
    const normalizedURL = normalizeRepositoryURL(pin.location);
    if (expected.has(normalizedURL)) throw new Error(`Duplicate SwiftPM repository in Package.resolved: ${pin.location}`);
    expected.set(normalizedURL, {
      identity: pin.identity,
      location: pin.location,
      revision: pin.state.revision.toLowerCase(),
      version: pin.state.version ?? null,
    });
  }
  return expected;
}

async function findUnsafeRepositoryEntry(repository) {
  const pending = [repository];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) return `symbolic link ${candidate}`;
      if (entry.isDirectory()) pending.push(candidate);
      else if (!entry.isFile()) return `unsupported filesystem entry ${candidate}`;
    }
  }
  return null;
}

function verifySafeGitConfiguration(repository) {
  const allowedKeys = new Set([
    "core.repositoryformatversion",
    "core.filemode",
    "core.bare",
    "core.ignorecase",
    "core.precomposeunicode",
    "core.symlinks",
    "core.fsmonitor",
    "core.longpaths",
    "remote.origin.url",
    "remote.origin.tagopt",
    "remote.origin.fetch",
    "remote.origin.mirror",
  ]);
  const keys = runGit(repository, ["config", "--local", "--name-only", "--list"])
    .split("\n")
    .filter(Boolean);
  const unsafeKey = keys.find((key) => !allowedKeys.has(key.toLowerCase()));
  if (unsafeKey) throw new Error(`unsafe Git configuration key ${unsafeKey}`);
  if (keys.some((key) => key.toLowerCase() === "core.fsmonitor")) {
    const fsmonitor = runGit(repository, ["config", "--local", "--get", "core.fsmonitor"]);
    if (fsmonitor !== "false") throw new Error("core.fsmonitor must be disabled");
  }
}

async function verifySafeGitHooks(repository) {
  const hooksDirectory = path.join(repository, "hooks");
  if (!(await exists(hooksDirectory))) return;
  for (const entry of await fs.readdir(hooksDirectory, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".sample")) {
      throw new Error(`unsafe Git hook entry ${path.join(hooksDirectory, entry.name)}`);
    }
  }
}

async function cacheFilesForManifest(cacheRoot, manifestName) {
  return (await collectFiles(cacheRoot))
    .filter((filePath) => path.relative(cacheRoot, filePath).split(path.sep).join("/") !== manifestName)
    .sort((left, right) => left.localeCompare(right));
}

async function clearSwiftpmCache(cacheRoot, reason) {
  warn("SwiftPM cache rejected", `${reason}; dependencies will be downloaded normally.`);
  await fs.rm(cacheRoot, { force: true, recursive: true });
  await fs.mkdir(cacheRoot, { recursive: true });
}

async function swiftpmIdentity(resolvedPath, swiftVersion) {
  return {
    resolvedSha256: await sha256(resolvedPath),
    swiftVersion,
  };
}

async function verifySwiftpmManifest(cacheRoot, repositoriesRoot, identity) {
  const manifestName = ".lithe-integrity.json";
  const manifestPath = path.join(cacheRoot, manifestName);
  const actualFiles = await cacheFilesForManifest(repositoriesRoot, manifestName);
  if (!(await exists(manifestPath))) {
    if (actualFiles.length > 0) {
      await clearSwiftpmCache(cacheRoot, "integrity manifest is missing");
      return false;
    }
    return true;
  }
  let manifest;
  try {
    manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  } catch (error) {
    await clearSwiftpmCache(cacheRoot, `integrity manifest is invalid (${error.message})`);
    return false;
  }
  if (manifest.schemaVersion !== 1 || !manifest.files || typeof manifest.files !== "object") {
    await clearSwiftpmCache(cacheRoot, "integrity manifest has an unsupported schema");
    return false;
  }
  if (manifest.swiftVersion !== identity.swiftVersion) {
    await clearSwiftpmCache(cacheRoot, "Swift version does not match the current build");
    return false;
  }
  const expectedNames = Object.keys(manifest.files).sort((left, right) => left.localeCompare(right));
  const actualNames = actualFiles.map((filePath) => path.relative(repositoriesRoot, filePath).split(path.sep).join("/"));
  if (expectedNames.length !== actualNames.length || expectedNames.some((name, index) => name !== actualNames[index])) {
    await clearSwiftpmCache(cacheRoot, "file set does not match the integrity manifest");
    return false;
  }
  for (let index = 0; index < actualFiles.length; index += 1) {
    if ((await sha256(actualFiles[index])) !== manifest.files[actualNames[index]]) {
      await clearSwiftpmCache(cacheRoot, `${actualNames[index]} has a SHA-256 mismatch`);
      return false;
    }
  }
  if (manifest.resolvedSha256 !== identity.resolvedSha256) {
    warn(
      "SwiftPM dependency graph changed",
      "Package.resolved SHA-256 changed; verified repositories will be filtered against the current pinned revisions.",
    );
  }
  return true;
}

async function verifySwiftpmRepositories(cacheRoot, expected, requireAll) {
  const matched = new Set();
  let removed = 0;
  if (!(await exists(cacheRoot))) await fs.mkdir(cacheRoot, { recursive: true });
  const rootStatus = await fs.lstat(cacheRoot);
  if (rootStatus.isSymbolicLink() || !rootStatus.isDirectory()) {
    throw new Error(`SwiftPM cache root must be a real directory: ${cacheRoot}`);
  }
  for (const entry of await fs.readdir(cacheRoot, { withFileTypes: true })) {
    if (entry.name === ".lithe-integrity.json") continue;
    const repository = path.join(cacheRoot, entry.name);
    try {
      if (entry.isSymbolicLink() || !entry.isDirectory()) throw new Error(`unsafe cache entry ${repository}`);
      const unsafeEntry = await findUnsafeRepositoryEntry(repository);
      if (unsafeEntry) throw new Error(unsafeEntry);
      await verifySafeGitHooks(repository);
      verifySafeGitConfiguration(repository);
      if (runGit(repository, ["rev-parse", "--is-bare-repository"]) !== "true") {
        throw new Error(`${repository} is not a bare Git repository`);
      }
      const remoteURL = runGit(repository, ["remote", "get-url", "origin"]);
      const normalizedURL = normalizeRepositoryURL(remoteURL);
      const pin = expected.get(normalizedURL);
      if (!pin) throw new Error(`${remoteURL} is not referenced by Package.resolved`);
      if (matched.has(normalizedURL)) throw new Error(`duplicate cached repository ${remoteURL}`);
      runGit(repository, ["fsck", "--full", "--no-dangling"]);
      runGit(repository, ["cat-file", "-e", `${pin.revision}^{commit}`]);
      matched.add(normalizedURL);
    } catch (error) {
      warn("SwiftPM cache entry rejected", `${entry.name}: ${error.message}; SwiftPM will fetch it normally.`);
      await fs.rm(repository, { force: true, recursive: true });
      removed += 1;
    }
  }
  if (requireAll) {
    const missing = [...expected.keys()].filter((repositoryURL) => !matched.has(repositoryURL));
    if (missing.length > 0) throw new Error(`SwiftPM cache is missing ${missing.length} pinned repository/repositories`);
  }
  return { verified: matched.size, removed };
}

async function writeSwiftpmManifest(cacheRoot, repositoriesRoot, identity) {
  const manifestName = ".lithe-integrity.json";
  const files = {};
  for (const filePath of await cacheFilesForManifest(repositoriesRoot, manifestName)) {
    const relative = path.relative(repositoriesRoot, filePath).split(path.sep).join("/");
    files[relative] = await sha256(filePath);
  }
  await fs.writeFile(
    path.join(cacheRoot, manifestName),
    `${JSON.stringify({ schemaVersion: 1, ...identity, files })}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`SwiftPM dependency cache sealed: ${Object.keys(files).length} file(s).\n`);
}

async function verifySwiftpmCache(cacheRoot, resolvedPath, swiftVersion, writeManifest) {
  if (!cacheRoot || !resolvedPath || !swiftVersion) return;
  const identity = await swiftpmIdentity(resolvedPath, swiftVersion);
  await fs.mkdir(cacheRoot, { recursive: true });
  const repositoriesRoot = path.join(cacheRoot, "repositories");
  await fs.mkdir(repositoriesRoot, { recursive: true });
  if (!writeManifest && !(await verifySwiftpmManifest(cacheRoot, repositoriesRoot, identity))) return;
  const expected = await expectedSwiftRepositories(resolvedPath);
  try {
    const result = await verifySwiftpmRepositories(repositoriesRoot, expected, writeManifest);
    if (writeManifest) await writeSwiftpmManifest(cacheRoot, repositoriesRoot, identity);
    else process.stdout.write(`SwiftPM dependency cache verified: ${result.verified} repository/repositories, ${result.removed} rejected.\n`);
  } catch (error) {
    await clearSwiftpmCache(cacheRoot, error.message);
    if (writeManifest) throw error;
  }
}

async function verifyBunIdentity(expectedVersion, lockPath) {
  if (!expectedVersion || !lockPath) return;
  const result = spawnSync("bun", ["--version"], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`Could not query Bun version: ${result.stderr || result.error}`);
  const actualVersion = result.stdout.trim();
  if (actualVersion !== expectedVersion) {
    throw new Error(`Bun ${expectedVersion} is required, but ${actualVersion} is active`);
  }
  const lockHash = await sha256(lockPath);
  process.stdout.write(`Bun cache identity verified: version ${actualVersion}, lock SHA-256 ${lockHash}.\n`);
  return { actualVersion, lockHash };
}

async function bunCacheFiles(cacheRoot) {
  const manifestName = ".lithe-integrity.json";
  const files = [];
  if (!(await exists(cacheRoot))) return files;
  const rootStatus = await fs.lstat(cacheRoot);
  if (rootStatus.isSymbolicLink() || !rootStatus.isDirectory()) {
    throw new Error(`Bun cache root must be a real directory: ${cacheRoot}`);
  }
  const pending = [cacheRoot];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`Bun cache contains a symbolic link and cannot be trusted: ${candidate}`);
      }
      if (entry.isDirectory()) pending.push(candidate);
      else if (entry.isFile() && entry.name !== manifestName) files.push(candidate);
      else if (!entry.isFile()) throw new Error(`Bun cache contains an unsupported entry: ${candidate}`);
    }
  }
  return files.sort((left, right) => left.localeCompare(right));
}

async function clearBunCache(cacheRoot, reason) {
  warn("Bun cache rejected", `${reason}; dependencies will be downloaded normally.`);
  await fs.rm(cacheRoot, { force: true, recursive: true });
  await fs.mkdir(cacheRoot, { recursive: true });
}

async function writeBunManifest(cacheRoot, identity) {
  await fs.mkdir(cacheRoot, { recursive: true });
  const files = {};
  for (const filePath of await bunCacheFiles(cacheRoot)) {
    const relative = path.relative(cacheRoot, filePath).split(path.sep).join("/");
    files[relative] = await sha256(filePath);
  }
  const manifest = {
    schemaVersion: 1,
    bunVersion: identity.actualVersion,
    lockSha256: identity.lockHash,
    files,
  };
  await fs.writeFile(
    path.join(cacheRoot, ".lithe-integrity.json"),
    `${JSON.stringify(manifest)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`Bun download cache sealed: ${Object.keys(files).length} file(s).\n`);
}

async function verifyBunCache(cacheRoot, identity) {
  if (!(await exists(cacheRoot))) return;
  const manifestPath = path.join(cacheRoot, ".lithe-integrity.json");
  const actualFiles = await bunCacheFiles(cacheRoot);
  if (!(await exists(manifestPath))) {
    if (actualFiles.length > 0) await clearBunCache(cacheRoot, "integrity manifest is missing");
    return;
  }

  let manifest;
  try {
    manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  } catch (error) {
    await clearBunCache(cacheRoot, `integrity manifest is invalid (${error.message})`);
    return;
  }
  if (
    manifest.schemaVersion !== 1 ||
    manifest.bunVersion !== identity.actualVersion ||
    manifest.lockSha256 !== identity.lockHash ||
    !manifest.files ||
    typeof manifest.files !== "object"
  ) {
    await clearBunCache(cacheRoot, "version or lock SHA-256 does not match the current build");
    return;
  }

  const expectedNames = Object.keys(manifest.files).sort((left, right) => left.localeCompare(right));
  const actualNames = actualFiles.map((filePath) => path.relative(cacheRoot, filePath).split(path.sep).join("/"));
  if (expectedNames.length !== actualNames.length || expectedNames.some((name, index) => name !== actualNames[index])) {
    await clearBunCache(cacheRoot, "file set does not match the integrity manifest");
    return;
  }
  for (let index = 0; index < actualFiles.length; index += 1) {
    const actualHash = await sha256(actualFiles[index]);
    if (actualHash !== manifest.files[actualNames[index]]) {
      await clearBunCache(cacheRoot, `${actualNames[index]} has a SHA-256 mismatch`);
      return;
    }
  }
  process.stdout.write(`Bun download cache verified: ${actualFiles.length} file(s).\n`);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!options.skipCargo) {
    await verifyCargoCache(path.resolve(options.cargoCache), options.cargoLocks.map((item) => path.resolve(item)));
  }
  await verifyJdtlsCache(
    options.jdtlsCache ? path.resolve(options.jdtlsCache) : null,
    options.jdtlsManifest ? path.resolve(options.jdtlsManifest) : null,
  );
  await verifyJdkCache(
    options.jdkCache ? path.resolve(options.jdkCache) : null,
    options.jdkManifest ? path.resolve(options.jdkManifest) : null,
  );
  await verifySwiftpmCache(
    options.swiftpmCache ? path.resolve(options.swiftpmCache) : null,
    options.swiftpmResolved ? path.resolve(options.swiftpmResolved) : null,
    options.swiftVersion,
    options.writeSwiftpmManifest,
  );
  const bunIdentity = await verifyBunIdentity(
    options.bunVersion,
    options.bunLock ? path.resolve(options.bunLock) : null,
  );
  if (bunIdentity && options.bunCache) {
    const bunCache = path.resolve(options.bunCache);
    if (options.writeBunManifest) await writeBunManifest(bunCache, bunIdentity);
    else await verifyBunCache(bunCache, bunIdentity);
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
