#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { publishDirectory } from "./reuse-worktree-resources.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const reuseScript = path.join(scriptDirectory, "reuse-worktree-resources.mjs");
const emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const testRoot = await fs.mkdtemp(path.join(os.tmpdir(), "lithe-worktree-resources-"));
const sourceRoot = path.join(testRoot, "source");
const targetRoot = path.join(testRoot, "target");

async function testFailedBackupPreservesDestination() {
  const root = path.join(testRoot, "publish");
  const destination = path.join(root, "destination");
  const staging = path.join(root, "staging");
  await fs.mkdir(destination, { recursive: true });
  await fs.mkdir(staging, { recursive: true });
  await fs.writeFile(path.join(destination, "old.txt"), "old");
  await fs.writeFile(path.join(staging, "new.txt"), "new");

  await assert.rejects(
    publishDirectory(staging, destination, async () => {}, async () => {
      throw new Error("simulated backup rename failure");
    }),
    /simulated backup rename failure/,
  );
  assert.equal(await fs.readFile(path.join(destination, "old.txt"), "utf8"), "old");
  await assert.rejects(fs.access(path.join(destination, "new.txt")));
}

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
  await test("distribution runtime state cannot be listed or imported as a build cache", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const state = registry.excludedResources.find(item => item.id === "distribution-runtime-state");
    assert.equal(state.reusable, false);
    assert.ok(state.locations.some(location => location.includes(".lithe-dev-profile-import-<transaction>")));
    assert.ok(state.locations.some(location => location.endsWith(".stable-profile-import-v1.plist")));
    assert.ok(state.locations.some(location => location.endsWith(".stable-profile-import-v1-staging/")));
    assert.ok(state.locations.some(location => location.endsWith(".stable-profile-import-v1")));
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes(state.id));
    const refused = reuse(["--resource", state.id]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /distribution-runtime-state is isolated/);
  });
  await test("application log state and export snapshots cannot be reused", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "application-log-state");
    assert.equal(resource.reusable, false);
    assert.ok(resource.locations.some(location => location.includes("diagnostics-export")));
    const result = reuse(["--resource", resource.id]);
    assert.notEqual(result.status, 0);
    assert.match(diagnostics(result), /application-log-state.*cannot be reused/);
  });
  await test("plugin UI icons remain owned by their verified installed package", { timeout: 15000 }, () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("plugin-ui-icons"));
    const refused = reuse(["--resource", "plugin-ui-icons"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /plugin-ui-icons.*cannot be reused/);
  });
  await test("test JFR recordings remain isolated to their worker and run", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "test-jfr-recordings");
    assert.equal(resource.reusable, false);
    assert.match(resource.identity, /PID.*process start identity.*JDK/);
    const rejected = reuse(["--resource", "test-jfr-recordings"]);
    assert.notEqual(rejected.status, 0);
    assert.match(diagnostics(rejected), /test-jfr-recordings.*cannot be reused/);
  });
  await test("bundled UI fonts come from Git and cannot be copied from worktree artifacts", { timeout: 15000 }, async () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("bundled-ui-fonts"));
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const fonts = registry.excludedResources.find(resource => resource.id === "bundled-ui-fonts");
    assert.match(fonts.identity, /Inter 4\.1.*18 static OTF.*JetBrains Mono 2\.304.*16 static TTF/);
    assert.match(fonts.identity, /Nerd Fonts v3\.5\.1.*four complete patched TTF/);
    const rejected = run(process.execPath, [reuseScript, "--source", sourceRoot, "--resource", "bundled-ui-fonts"]);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /bundled-ui-fonts is isolated/);
  });
  await test("AutoBuild plugin mirror staging is validated and never reused", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "autobuild-plugin-mirror-staging");
    assert.equal(resource.reusable, false);
    assert.ok(resource.locations.includes("<RUNNER_TEMP>/lithe-autobuild-<invocation>/baselines/"));
    assert.ok(resource.locations.includes("<RUNNER_TEMP>/lithe-autobuild-<invocation>/autobuild-publication.json"));
    assert.match(resource.identity, /publication checkpoint.*sorted target asset SHA-256\/size.*exact-plan recovery/);
    assert.match(resource.identity, /build\/ISO timestamp.*strict publication-time ordering/);
    assert.match(resource.identity, /baselines\/AutoBuild.*baselines\/preview-0\.3\.0.*legacy release remains/);
    assert.match(resource.identity, /source SHA.*SHA-256.*official organization/);
    assert.ok(resource.locations.every(location => location.startsWith("<RUNNER_TEMP>/lithe-autobuild-<invocation>/")));
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes(resource.id));
    const refused = reuse(["--resource", resource.id]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /autobuild-plugin-mirror-staging is isolated/);
  });
  await test("Sparkle baseline staging is never listed or copied between worktrees", { timeout: 15000 }, () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("sparkle-baseline-staging"));
    const refused = reuse(["--resource", "sparkle-baseline-staging"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /sparkle-baseline-staging.*\.baseline-.*cannot be reused/);
  });
  await test("frontend install temp data and dependencies cannot cross worktrees", { timeout: 15000 }, () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("frontend-install-state"));
    const refused = reuse(["--resource", "frontend-install-state"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /frontend-install-state.*node_modules.*bun-tmp.*cannot be reused/);
  });
  await test("Java launch files are never listed or copied between worktrees", { timeout: 15000 }, () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("java-launch-temporaries"));
    const refused = reuse(["--resource", "java-launch-temporaries"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /java-launch-temporaries.*classpath\.jar.*cannot be reused/);
  });
  await test("IDE MCP credentials and helpers cannot cross worktrees", { timeout: 15000 }, () => {
    const refused = reuse(["--resource", "ide-mcp"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /ide-mcp.*cannot be reused/);
  });
  await test("generated matrix views cannot be copied across worktrees", { timeout: 15000 }, () => {
    const refused = reuse(["--resource", "platform-feature-matrix"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /platform-feature-matrix.*cannot be reused/);
  });

  await test("Agent fixture screenshots cannot be copied as reusable resources", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "agent-ui-test-evidence");
    assert.equal(resource?.reusable, false);
    assert.ok(resource.locations.includes(".artifacts/test-stability/*.png"));
    const rejected = reuse(["--resource", "agent-ui-test-evidence"]);
    assert.notEqual(rejected.status, 0);
    assert.ok(resource.locations.some(location => location.includes("lithe-localized-logging")));
    assert.match(diagnostics(rejected), /agent-ui-test-evidence.*cannot be reused/);
  });

  await test("user-owned CLI installations are excluded from worktree copying", { timeout: 15000 }, () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("agent-cli-runtime"));
    const refused = reuse(["--resource", "agent-cli-runtime"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /agent-cli-runtime.*cannot be reused/);
  });
  await test("per-launch Codex retry/context relays cannot be listed or copied", { timeout: 15000 }, async () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes("codex-retry-relay"));
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "codex-retry-relay");
    assert.match(resource.identity, /context reports.*per-load tickets/);
    const refused = reuse(["--resource", "codex-retry-relay"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /codex-retry-relay.*lithe-codex-retry.*cannot be reused/);
  });
  await test("Agent history preferences and exports are excluded from worktree copying", { timeout: 15000 }, () => {
    const refused = reuse(["--resource", "agent-history-metadata"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /agent-history-metadata.*lithe\.agent-history\.v1.*cannot be reused/);
  });
  await test("JDT Maven settings snapshots cannot be copied between worktrees", { timeout: 15000 }, () => {
    const refused = reuse(["--resource", "jdt-maven-settings"]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /jdt-maven-settings.*cannot be reused/);
  });
  await test("plugin web state has no transferable build identity or copy stage", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "plugin-web-state");
    assert.equal(resource.reusable, false);
    assert.ok(resource.locations.some(location => location.includes("web-state/<window-id>/<workspace-digest>.json")));
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes(resource.id));
    const refused = reuse(["--resource", resource.id]);
    assert.notEqual(refused.status, 0);
    assert.match(diagnostics(refused), /plugin-web-state.*cannot be reused/);
  });
  await test("plugin packages and marketplace state stay isolated in each worktree", { timeout: 15000 }, () => {
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    for (const id of ["official-plugin-packages", "plugin-marketplace-state"]) {
      assert.ok(!listed.stdout.includes(id));
      const refused = reuse(["--resource", id]);
      assert.notEqual(refused.status, 0);
      assert.match(diagnostics(refused), new RegExp(`${id}.*cannot be reused`));
    }
  });
  await test("local disk snapshots and approvals are rejected before any worktree access", { timeout: 15000 }, async () => {
    const registry = JSON.parse(await fs.readFile(path.join(scriptDirectory, "worktree-resources.json"), "utf8"));
    const resource = registry.excludedResources.find(item => item.id === "plugin-disk-install-state");
    assert.equal(resource.reusable, false);
    assert.ok(resource.locations.includes("<file-storage-temp>/lithe-plugin-disk-<UUID>/"));
    assert.ok(resource.locations.includes("<file-storage-temp>/lithe-plugin-disk-<UUID>/archive.zip"));
    assert.ok(resource.locations.includes("<file-storage-temp>/lithe-plugin-disk-<UUID>/package/"));
    assert.ok(resource.locations.includes("<app-support>/Lithe/Plugins/.staging/<transaction>/"));
    assert.ok(resource.locations.includes("<app-support>/Lithe/Plugins/<plugin-id>/versions/<version>/"));
    assert.ok(resource.locations.includes("<app-support>/Lithe/Plugins/<plugin-id>/installation.json"));
    const listed = run(process.execPath, [reuseScript, "--list"]);
    assertSucceeded(listed);
    assert.ok(!listed.stdout.includes(resource.id));

    // A mixed request must fail before resolving even the valid cache's roots:
    // neither missing source nor missing target should ever be touched or created.
    const missingSource = path.join(testRoot, "unopened-disk-source");
    const missingTarget = path.join(testRoot, "unopened-disk-target");
    for (const id of [resource.id, "plugin-marketplace-state"]) {
      const refused = run(process.execPath, [
        reuseScript, "--source", missingSource, "--target", missingTarget,
        "--resource", "jdtls", "--resource", id,
      ]);
      assert.notEqual(refused.status, 0);
      assert.match(diagnostics(refused), new RegExp(`${id} is isolated.*cannot be reused`));
      await assert.rejects(fs.access(missingSource), { code: "ENOENT" });
      await assert.rejects(fs.access(missingTarget), { code: "ENOENT" });
    }
  });
  await testFailedBackupPreservesDestination();
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

  const staleLock = path.join(targetRoot, ".artifacts", ".reuse-worktree-resources.lock");
  await fs.mkdir(staleLock, { recursive: true });
  const exitedProcess = spawn(process.execPath, ["-e", ""], { stdio: "ignore" });
  await new Promise((resolve, reject) => {
    exitedProcess.once("error", reject);
    exitedProcess.once("exit", resolve);
  });
  await fs.writeFile(
    path.join(staleLock, "owner.json"),
    `${JSON.stringify({ pid: exitedProcess.pid, startedAt: new Date().toISOString() })}\n`,
  );

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

  result = run(process.execPath, [reuseScript, "--source", sourceRoot, "--target", targetRoot, "--resource", "language-tools"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /language-tools is isolated/);

  for (const id of ["windows-worker-plugins", "installed-worker-plugins"]) {
    const result = run(process.execPath, [reuseScript, "--source", sourceRoot, "--resource", id]);
    assert.notEqual(result.status, 0);
    assert.match(diagnostics(result), /isolated/);
  }

  process.stdout.write("Worktree resource reuse tests passed.\n");
} finally {
  await fs.rm(testRoot, { force: true, recursive: true });
}
