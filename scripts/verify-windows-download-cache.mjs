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
    jdtlsCache: null,
    jdtlsManifest: null,
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
    const value = argv[index + 1];
    if (!value) throw new Error(`${option} requires a value`);
    index += 1;
    if (option === "--cargo-cache") options.cargoCache = value;
    else if (option === "--cargo-lock") options.cargoLocks.push(value);
    else if (option === "--jdtls-cache") options.jdtlsCache = value;
    else if (option === "--jdtls-manifest") options.jdtlsManifest = value;
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
  await verifyCargoCache(path.resolve(options.cargoCache), options.cargoLocks.map((item) => path.resolve(item)));
  await verifyJdtlsCache(
    options.jdtlsCache ? path.resolve(options.jdtlsCache) : null,
    options.jdtlsManifest ? path.resolve(options.jdtlsManifest) : null,
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
