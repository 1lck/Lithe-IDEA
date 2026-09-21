#!/usr/bin/env node

import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const reuseScript = path.join(scriptDirectory, "reuse-worktree-resources.mjs");
const { publishDirectory, validatorArguments } = await import(pathToFileURL(reuseScript).href);
const emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const testRoot = await fs.mkdtemp(path.join(os.tmpdir(), "lithe-worktree-resources-"));
const sourceRoot = path.join(testRoot, "source");
const targetRoot = path.join(testRoot, "target");

function run(command, argumentsList, workingDirectory = testRoot) {
  const result = spawnSync(command, argumentsList, {
    cwd: workingDirectory,
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.notEqual(result.error?.code, "ETIMEDOUT", `${command} timed out`);
  return result;
}

function diagnostics(result) {
  return [result.stdout, result.stderr].filter(Boolean).join("\n");
}

function assertSucceeded(result) {
  assert.equal(result.status, 0, diagnostics(result));
}

function reuse(extraArguments = []) {
  return run(process.execPath, [
    reuseScript,
    "--source", sourceRoot,
    "--target", targetRoot,
    "--resource", "jdtls",
    ...extraArguments,
  ]);
}

try {
  await fs.mkdir(path.join(sourceRoot, "third_party", "jdtls"), { recursive: true });
  await fs.writeFile(
    path.join(sourceRoot, "third_party", "jdtls", "manifest.json"),
    `${JSON.stringify({
      version: "1.0.0",
      archiveSHA256: emptySha256,
      licenseSHA256: emptySha256,
      lombokVersion: "1.0.0",
      lombokSHA256: emptySha256,
      lombokLicenseSHA256: emptySha256,
      javaDebugExtensionVersion: "1.0.0",
      javaDebugServerVersion: "1.0.0",
      javaDebugArchiveSHA256: emptySha256,
      javaDebugLicenseSHA256: emptySha256,
      javaTestExtensionVersion: "1.0.0",
      javaTestArchiveSHA256: emptySha256,
      javaTestLicenseSHA256: emptySha256,
    })}\n`,
  );
  assertSucceeded(run("git", ["init", "--quiet", "--initial-branch=main"], sourceRoot));
  assertSucceeded(run("git", ["config", "user.name", "Resource Reuse Test"], sourceRoot));
  assertSucceeded(run("git", ["config", "user.email", "resource-reuse@example.invalid"], sourceRoot));
  assertSucceeded(run("git", ["add", "third_party/jdtls/manifest.json"], sourceRoot));
  assertSucceeded(run("git", ["commit", "--quiet", "-m", "fixture"], sourceRoot));
  assertSucceeded(run("git", ["worktree", "add", "--quiet", "--detach", targetRoot], sourceRoot));

  const cache = path.join(sourceRoot, ".artifacts", "jdtls-downloads");
  const expectedFiles = [
    `jdtls-1.0.0-${emptySha256}.tar.gz`,
    `EPL-2.0-${emptySha256}.txt`,
    `lombok-1.0.0-${emptySha256}.jar`,
    `lombok-MIT-1.0.0-${emptySha256}.txt`,
    `vscode-java-debug-1.0.0-${emptySha256}.vsix`,
    `java-debug-EPL-1.0-1.0.0-${emptySha256}.txt`,
    `vscode-java-test-1.0.0-${emptySha256}.vsix`,
    `java-test-MIT-1.0.0-${emptySha256}.txt`,
  ];
  await fs.mkdir(cache, { recursive: true });
  for (const fileName of expectedFiles) await fs.writeFile(path.join(cache, fileName), "");

  let result = reuse();
  assertSucceeded(result);
  assert.match(result.stdout, /Reused jdtls: published 8 verified file/);
  const targetCache = path.join(targetRoot, ".artifacts", "jdtls-downloads");
  for (const fileName of expectedFiles) await fs.access(path.join(targetCache, fileName));

  const archiveName = expectedFiles[0];
  await fs.writeFile(path.join(cache, archiveName), "corrupted");
  result = reuse();
  assertSucceeded(result);
  assert.match(result.stdout, /Keeping jdtls: target already has 8 verified file/);
  assert.match(await fs.readFile(path.join(targetCache, archiveName), "utf8"), /^$/);
  assert.match(diagnostics(result), /SHA-256 mismatch/);

  await fs.rm(path.join(targetCache, archiveName));
  await fs.writeFile(path.join(cache, archiveName), "");
  result = reuse();
  assertSucceeded(result);
  assert.match(result.stdout, /Reused jdtls: published 8 verified file/);
  await fs.access(path.join(targetCache, archiveName));

  result = run(process.execPath, [reuseScript, "--source", sourceRoot, "--target", targetRoot, "--resource", "unknown"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Unknown resource: unknown/);

  result = run(process.execPath, [reuseScript, "--source", sourceRoot, "--target", sourceRoot, "--resource", "jdtls"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must be different/);

  result = run(process.execPath, [reuseScript, "--list"]);
  assertSucceeded(result);
  assert.match(result.stdout, /^cargo\t\.artifacts\/cargo-home\/registry\/cache$/m);
  assert.match(result.stdout, /^jdk\t\.artifacts\/jdk-downloads$/m);

  const rollbackRoot = path.join(testRoot, "rollback");
  const rollbackDestination = path.join(rollbackRoot, "cache");
  const rollbackStaging = path.join(rollbackRoot, "cache.staging");
  await fs.mkdir(rollbackDestination, { recursive: true });
  await fs.mkdir(rollbackStaging, { recursive: true });
  await fs.writeFile(path.join(rollbackDestination, "old.txt"), "old");
  await fs.writeFile(path.join(rollbackStaging, "new.txt"), "new");
  await assert.rejects(
    publishDirectory(rollbackStaging, rollbackDestination, async () => {}, async () => {
      throw new Error("simulated backup rename failure");
    }),
    /Could not back up existing cache/,
  );
  assert.equal(await fs.readFile(path.join(rollbackDestination, "old.txt"), "utf8"), "old");
  await fs.access(path.join(rollbackStaging, "new.txt"));

  await fs.mkdir(path.join(targetRoot, "rust"), { recursive: true });
  await fs.mkdir(path.join(targetRoot, "windows", "tauri", "src-tauri"), { recursive: true });
  await fs.writeFile(path.join(targetRoot, "rust", "Cargo.lock"), "fixture");
  await fs.writeFile(path.join(targetRoot, "windows", "tauri", "src-tauri", "Cargo.lock"), "fixture");
  assert.deepEqual(
    await validatorArguments({ validator: "cargo" }, path.join(targetRoot, ".artifacts", "cargo-cache"), targetRoot),
    [
      "--cargo-cache", path.join(targetRoot, ".artifacts", "cargo-cache"),
      "--cargo-lock", path.join(targetRoot, "rust", "Cargo.lock"),
      "--cargo-lock", path.join(targetRoot, "windows", "tauri", "src-tauri", "Cargo.lock"),
    ],
  );

  await fs.mkdir(path.join(sourceRoot, ".artifacts", "jdk-downloads"), { recursive: true });
  await fs.writeFile(path.join(sourceRoot, ".artifacts", "jdk-downloads", "source.bin"), "source");
  result = run(process.execPath, [
    reuseScript,
    "--source", sourceRoot,
    "--target", targetRoot,
    "--resource", "jdk",
    "--resource", "jdtls",
  ]);
  assert.notEqual(result.status, 0);
  assert.match(diagnostics(result), /Failed jdk:/);
  assert.match(result.stdout, /Keeping jdtls: target already has 8 verified file/);

  const targetArtifacts = path.join(targetRoot, ".artifacts");
  const lock = path.join(targetArtifacts, ".reuse-worktree-resources.lock");
  await fs.mkdir(lock, { recursive: true });
  await fs.writeFile(path.join(lock, "owner.json"), JSON.stringify({ pid: 123, startedAt: "test" }));
  result = reuse();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /confirm no active process before removing it/);
  await fs.rm(lock, { force: true, recursive: true });

  const orphanStaging = path.join(targetArtifacts, "jdtls-downloads.staging-stale");
  const orphanBackup = path.join(targetArtifacts, "jdtls-downloads.backup-stale");
  await fs.mkdir(orphanStaging, { recursive: true });
  await fs.mkdir(orphanBackup, { recursive: true });
  result = reuse();
  assertSucceeded(result);
  await assert.rejects(fs.access(orphanStaging));
  await assert.rejects(fs.access(orphanBackup));

  process.stdout.write("Worktree resource reuse tests passed.\n");
} finally {
  await fs.rm(testRoot, { force: true, recursive: true });
}
