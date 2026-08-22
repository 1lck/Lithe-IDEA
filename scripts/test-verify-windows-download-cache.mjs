#!/usr/bin/env node

import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const verifier = path.join(scriptDirectory, "verify-windows-download-cache.mjs");
const emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const testRoot = await fs.mkdtemp(path.join(os.tmpdir(), "lithe-cache-verifier-"));

function verify(argumentsList, environment = process.env) {
  return spawnSync(process.execPath, [verifier, ...argumentsList], { encoding: "utf8", env: environment });
}

try {
  const cargoCache = path.join(testRoot, "cargo-cache", "registry");
  const cargoLock = path.join(testRoot, "Cargo.lock");
  const crate = path.join(cargoCache, "fixture-1.0.0.crate");
  await fs.mkdir(cargoCache, { recursive: true });
  await fs.writeFile(
    cargoLock,
    `version = 4\n\n[[package]]\nname = "fixture"\nversion = "1.0.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "${emptySha256}"\n`,
  );
  await fs.writeFile(crate, "");

  let result = verify(["--cargo-cache", cargoCache, "--cargo-lock", cargoLock]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(await fs.readFile(crate, "utf8"), "");

  await fs.writeFile(crate, "corrupted");
  result = verify(["--cargo-cache", cargoCache, "--cargo-lock", cargoLock]);
  assert.equal(result.status, 0, result.stderr);
  await assert.rejects(fs.access(crate));
  assert.match(result.stderr, /SHA-256 mismatch/);

  const jdtlsCache = path.join(testRoot, "jdtls-cache");
  const jdtlsManifest = path.join(testRoot, "manifest.json");
  const jdtlsArchive = path.join(jdtlsCache, `jdtls-1.0.0-${emptySha256}.tar.gz`);
  const unexpected = path.join(jdtlsCache, "unexpected.download");
  await fs.mkdir(jdtlsCache, { recursive: true });
  await fs.writeFile(
    jdtlsManifest,
    JSON.stringify({
      version: "1.0.0",
      archiveSHA256: emptySha256,
      licenseSHA256: emptySha256,
      lombokVersion: "1.0.0",
      lombokSHA256: emptySha256,
      lombokLicenseSHA256: emptySha256,
    }),
  );
  await fs.writeFile(jdtlsArchive, "");
  await fs.writeFile(unexpected, "unexpected");

  result = verify([
    "--cargo-cache",
    cargoCache,
    "--cargo-lock",
    cargoLock,
    "--jdtls-cache",
    jdtlsCache,
    "--jdtls-manifest",
    jdtlsManifest,
  ]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(await fs.readFile(jdtlsArchive, "utf8"), "");
  await assert.rejects(fs.access(unexpected));
  assert.match(result.stderr, /not referenced by the JDTLS manifest/);

  const fakeBin = path.join(testRoot, "bin");
  const fakeBun = path.join(fakeBin, "bun");
  const bunCache = path.join(testRoot, "bun-cache");
  const bunLock = path.join(testRoot, "bun.lock");
  const cachedPackage = path.join(bunCache, "fixture@1.0.0", "index.js");
  await fs.mkdir(fakeBin, { recursive: true });
  await fs.writeFile(fakeBun, "#!/bin/sh\nprintf '1.3.14\\n'\n", { mode: 0o700 });
  await fs.mkdir(path.dirname(cachedPackage), { recursive: true });
  await fs.writeFile(bunLock, "fixture-lock\n");
  await fs.writeFile(cachedPackage, "export default 1;\n");
  const bunEnvironment = { ...process.env, PATH: `${fakeBin}${path.delimiter}${process.env.PATH}` };
  const bunArguments = [
    "--cargo-cache",
    cargoCache,
    "--cargo-lock",
    cargoLock,
    "--bun-version",
    "1.3.14",
    "--bun-lock",
    bunLock,
    "--bun-cache",
    bunCache,
  ];

  result = verify([...bunArguments, "--write-bun-manifest"], bunEnvironment);
  assert.equal(result.status, 0, result.stderr);
  await fs.access(path.join(bunCache, ".lithe-integrity.json"));
  result = verify(bunArguments, bunEnvironment);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Bun download cache verified: 1 file/);

  await fs.writeFile(cachedPackage, "tampered\n");
  result = verify(bunArguments, bunEnvironment);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stderr, /SHA-256 mismatch/);
  await assert.rejects(fs.access(cachedPackage));

  process.stdout.write("Windows download cache verifier tests passed.\n");
} finally {
  await fs.rm(testRoot, { force: true, recursive: true });
}
