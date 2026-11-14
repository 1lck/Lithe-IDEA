#!/usr/bin/env node

import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "../..");
const verifier = path.join(scriptDirectory, "verify-download-cache.mjs");
const emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const testRoot = await fs.mkdtemp(path.join(os.tmpdir(), "lithe-cache-verifier-"));
const testEnvironment = { ...process.env, GITHUB_ACTIONS: "false" };

function verify(argumentsList, environment = testEnvironment) {
  return spawnSync(process.execPath, [verifier, ...argumentsList], { encoding: "utf8", env: environment });
}

function diagnostics(result) {
  return [result.stdout, result.stderr].filter(Boolean).join("\n");
}

function assertSucceeded(result) {
  assert.equal(result.status, 0, diagnostics(result));
}

function run(command, argumentsList, workingDirectory = testRoot) {
  const result = spawnSync(command, argumentsList, { cwd: workingDirectory, encoding: "utf8" });
  assertSucceeded(result);
  return result.stdout.trim();
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
  assertSucceeded(result);
  assert.equal(await fs.readFile(crate, "utf8"), "");

  await fs.writeFile(crate, "corrupted");
  result = verify(["--cargo-cache", cargoCache, "--cargo-lock", cargoLock]);
  assertSucceeded(result);
  await assert.rejects(fs.access(crate));
  assert.match(diagnostics(result), /SHA-256 mismatch/);

  await fs.writeFile(crate, "corrupted in Actions mode");
  result = verify(
    ["--cargo-cache", cargoCache, "--cargo-lock", cargoLock],
    { ...testEnvironment, GITHUB_ACTIONS: "true" },
  );
  assertSucceeded(result);
  await assert.rejects(fs.access(crate));
  assert.equal(result.stderr, "");
  assert.match(result.stdout, /::warning title=Cargo cache entry rejected::.*SHA-256 mismatch/);

  // The ConPTY route accepts only the archive named by the pinned manifest; a
  // stale download or a tampered file must be removed so the build re-fetches it.
  const conptyCache = path.join(testRoot, "conpty-cache");
  const conptyManifest = path.join(testRoot, "conpty-manifest.json");
  const conptyPackage = path.join(conptyCache, "Microsoft.Windows.Console.ConPTY.1.0.0.nupkg");
  const olderConptyPackage = path.join(
    conptyCache,
    "Microsoft.Windows.Console.ConPTY.0.9.0.nupkg",
  );
  await fs.mkdir(conptyCache, { recursive: true });
  await fs.writeFile(
    conptyManifest,
    JSON.stringify({
      version: "1.0.0",
      packageSHA256: emptySha256,
      platforms: {
        "windows-x86_64": { conptyDLLSHA256: emptySha256, openConsoleSHA256: emptySha256 },
      },
    }),
  );
  await fs.writeFile(conptyPackage, "");
  await fs.writeFile(olderConptyPackage, "older release");

  const conptyArguments = [
    "--cargo-cache",
    cargoCache,
    "--cargo-lock",
    cargoLock,
    "--conpty-cache",
    conptyCache,
    "--conpty-manifest",
    conptyManifest,
  ];

  result = verify(conptyArguments);
  assertSucceeded(result);
  assert.equal(await fs.readFile(conptyPackage, "utf8"), "");
  await assert.rejects(fs.access(olderConptyPackage));
  assert.match(diagnostics(result), /not the pinned 1\.0\.0 package/);
  assert.match(result.stdout, /ConPTY download cache verified: 1 artifact/);

  await fs.writeFile(conptyPackage, "corrupted");
  result = verify(conptyArguments);
  assertSucceeded(result);
  await assert.rejects(fs.access(conptyPackage));
  assert.match(result.stdout, /ConPTY download cache verified: 0 artifact/);

  // The reuse registry must route this cache to the validator that owns it.
  const reuseScript = await fs.readFile(
    path.join(repositoryRoot, "scripts", "resources", "reuse-worktree-resources.mjs"),
    "utf8",
  );
  assert.match(reuseScript, /resource\.validator === "conpty"/, "ConPTY needs a reuse validator");
  assert.match(reuseScript, /--conpty-manifest/, "ConPTY reuse must pass its manifest");
  const worktreeRegistry = JSON.parse(
    await fs.readFile(path.join(repositoryRoot, "scripts", "resources", "worktree-resources.json"), "utf8"),
  );
  const conptyResource = worktreeRegistry.resources.find((entry) => entry.id === "conpty");
  assert.ok(conptyResource, "ConPTY download cache must be registered for reuse");
  assert.equal(conptyResource.validator, "conpty");
  assert.equal(conptyResource.path, ".artifacts/conpty-downloads");

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
  const bunEnvironment = { ...testEnvironment, PATH: `${fakeBin}${path.delimiter}${process.env.PATH}` };
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
  assertSucceeded(result);
  await fs.access(path.join(bunCache, ".lithe-integrity.json"));
  result = verify(bunArguments, bunEnvironment);
  assertSucceeded(result);
  assert.match(result.stdout, /Bun download cache verified: 1 file/);

  await fs.writeFile(cachedPackage, "tampered\n");
  result = verify(bunArguments, bunEnvironment);
  assertSucceeded(result);
  assert.match(diagnostics(result), /SHA-256 mismatch/);
  await assert.rejects(fs.access(cachedPackage));

  const swiftSource = path.join(testRoot, "swift-source");
  const swiftpmCache = path.join(testRoot, "swiftpm-cache");
  const swiftRepositoryRoot = path.join(swiftpmCache, "repositories");
  const swiftRepository = path.join(swiftRepositoryRoot, "fixture-dependency-deadbeef");
  const swiftResolved = path.join(testRoot, "Package.resolved");
  const swiftRemote = "https://github.com/example/fixture-dependency.git";
  await fs.mkdir(swiftSource, { recursive: true });
  run("git", ["init", "--quiet"], swiftSource);
  run("git", ["config", "user.name", "Cache Test"], swiftSource);
  run("git", ["config", "user.email", "cache-test@example.invalid"], swiftSource);
  await fs.writeFile(path.join(swiftSource, "Package.swift"), "// swift-tools-version: 6.2\n");
  run("git", ["add", "Package.swift"], swiftSource);
  run("git", ["commit", "--quiet", "-m", "fixture"], swiftSource);
  const swiftRevision = run("git", ["rev-parse", "HEAD"], swiftSource);
  await fs.mkdir(swiftRepositoryRoot, { recursive: true });
  run("git", ["clone", "--quiet", "--mirror", swiftSource, swiftRepository]);
  run("git", ["remote", "set-url", "origin", swiftRemote], swiftRepository);
  await fs.writeFile(
    swiftResolved,
    JSON.stringify({
      originHash: "fixture",
      pins: [{
        identity: "fixture-dependency",
        kind: "remoteSourceControl",
        location: swiftRemote,
        state: { revision: swiftRevision, version: "1.0.0" },
      }],
      version: 3,
    }),
  );
  const swiftpmArguments = [
    "--skip-cargo",
    "--swiftpm-cache",
    swiftpmCache,
    "--swiftpm-resolved",
    swiftResolved,
    "--swift-version",
    "6.2",
  ];
  result = verify([...swiftpmArguments, "--write-swiftpm-manifest"]);
  assertSucceeded(result);
  await fs.access(path.join(swiftpmCache, ".lithe-integrity.json"));
  result = verify(swiftpmArguments);
  assertSucceeded(result);
  assert.match(result.stdout, /SwiftPM dependency cache verified: 1 repository/);

  const changedResolved = JSON.parse(await fs.readFile(swiftResolved, "utf8"));
  changedResolved.originHash = "changed-fixture";
  await fs.writeFile(swiftResolved, JSON.stringify(changedResolved));
  result = verify(swiftpmArguments);
  assertSucceeded(result);
  assert.match(diagnostics(result), /Package\.resolved SHA-256 changed/);
  await fs.access(swiftRepository);

  await fs.writeFile(path.join(swiftRepository, "tampered"), "tampered\n");
  result = verify(swiftpmArguments);
  assertSucceeded(result);
  assert.match(diagnostics(result), /SHA-256 mismatch|file set does not match/);
  await assert.rejects(fs.access(swiftRepository));

  process.stdout.write("Download cache verifier tests passed.\n");
} finally {
  await fs.rm(testRoot, { force: true, recursive: true });
}
