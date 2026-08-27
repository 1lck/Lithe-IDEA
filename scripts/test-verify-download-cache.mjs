#!/usr/bin/env node

import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
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

async function assertWindowsBunCacheConfiguration() {
  const workflowPaths = [
    ".github/workflows/ci-windows.yml",
    ".github/workflows/release-preview-windows.yml",
    ".github/workflows/release-windows.yml",
  ];
  for (const relativePath of workflowPaths) {
    const contents = await fs.readFile(path.join(repositoryRoot, relativePath), "utf8");
    assert.match(contents, /^\s*path: \.artifacts\/bun-cache$/m, `${relativePath} must cache Bun's isolated path`);
    assert.match(contents, /BUN_INSTALL_CACHE_DIR=.*\.artifacts\/bun-cache/, `${relativePath} must configure the isolated Bun cache`);
    assert.match(contents, /BUN_TMPDIR=.*\.artifacts\/bun-tmp/, `${relativePath} must keep Bun temp files on the cache volume`);
    assert.match(contents, /BUN_FEATURE_FLAG_DISABLE_INSTALL_INDEX=1/, `${relativePath} must omit Bun's Windows junction index`);
    assert.match(contents, /bun-\$\{\{ steps\.bun\.outputs\.bun-version \}\}-v2-/, `${relativePath} must isolate the same-volume Bun cache format`);
    assert.match(contents, /^\s*path: \.artifacts\/jdk-downloads$/m, `${relativePath} must cache JDK downloads`);
    assert.match(contents, /jdk-v1-\$\{\{ hashFiles\('third_party\/jdk\/manifest\.json'\) \}\}/, `${relativePath} must key JDK downloads by manifest`);
  }

  const installer = await fs.readFile(path.join(repositoryRoot, "scripts/install-windows-frontend-dependencies.ps1"), "utf8");
  assert.match(installer, /\.artifacts\/bun-cache/, "Windows dependency installation must use the isolated Bun cache");
  assert.match(installer, /\.artifacts\/bun-tmp/, "Windows dependency installation must use a repository temp directory");
  assert.match(installer, /GetPathRoot\(\$bunCache\)/, "Windows dependency installation must resolve the cache volume");
  assert.match(installer, /GetPathRoot\(\$bunTemp\)/, "Windows dependency installation must resolve the temp volume");
  assert.match(installer, /\$env:BUN_TMPDIR = \$bunTemp/, "Windows dependency installation must enforce the same-volume temp directory");
  assert.match(installer, /\$env:BUN_FEATURE_FLAG_DISABLE_INSTALL_INDEX = "1"/, "Windows dependency installation must reject Bun's junction index");
  assert.doesNotMatch(installer, /throw "Could not seal the Bun download cache/, "Bun cache sealing failures must not fail the build");

  const validator = await fs.readFile(path.join(repositoryRoot, "scripts/validate-windows-build-caches.ps1"), "utf8");
  assert.match(validator, /\$bunCache = Join-Path \$artifactsRoot "bun-cache"/, "Windows cache validation must use the isolated Bun cache");
}

async function assertWindowsJavaToolingBuildConfiguration() {
  const buildScript = await fs.readFile(path.join(repositoryRoot, "scripts/build-windows.ps1"), "utf8");
  assert.match(buildScript, /prepare-jdtls\.ps1/, "Windows builds must prepare JDTLS");
  assert.match(buildScript, /prepare-jdk\.ps1[\s\S]*-RustTarget \$RustTarget/, "Windows builds must prepare the target JDK");
  assert.doesNotMatch(
    buildScript,
    /if \(\$Configuration -eq "Release"\) \{[\s\S]{0,1200}prepare-jdk\.ps1/,
    "Debug builds must not skip JDK preparation",
  );
  assert.match(buildScript, /LanguageServers\/jdk/, "Windows builds must stage the JDK next to the executable");

  const packageScript = await fs.readFile(path.join(repositoryRoot, "scripts/package-windows.ps1"), "utf8");
  assert.match(packageScript, /prepare-jdk\.ps1[\s\S]*-RustTarget \$RustTarget/, "Windows packages must prepare the target JDK");
  assert.match(packageScript, /bin\/java\.exe/, "Windows packages must validate the bundled java.exe");
  assert.match(packageScript, /Sync-BundleResource \$preparedJdkRoot[\s\S]*\.artifacts\/jdk/, "Windows packages must stage overrides at Tauri's canonical JDK path");

  const prepareScript = await fs.readFile(path.join(repositoryRoot, "scripts/prepare-jdk.ps1"), "utf8");
  assert.match(prepareScript, /"x86_64-pc-windows-msvc" \{ return "windows-x86_64" \}/);
  assert.match(prepareScript, /"aarch64-pc-windows-msvc" \{ return "windows-aarch64" \}/);
  assert.match(prepareScript, /\.lithe-jdk\.json/, "Prepared JDKs must carry a reusable identity stamp");
}

async function assertMacJdkCacheConfiguration() {
  const action = await fs.readFile(
    path.join(repositoryRoot, ".github/actions/prepare-macos-dependency-cache/action.yml"),
    "utf8",
  );
  assert.match(action, /^  jdk:$/m, "macOS cache action must expose the JDK cache");
  assert.match(action, /^  jdk-architecture:$/m, "macOS cache action must isolate target architectures");
  assert.match(action, /path: \.artifacts\/jdk-downloads/);
  assert.match(action, /macos-jdk-downloads-\$\{\{ runner\.os \}\}-\$\{\{ inputs\.jdk-architecture \}\}-/);

  for (const relativePath of [
    ".github/workflows/release-preview-macos.yml",
    ".github/workflows/release-macos.yml",
  ]) {
    const workflow = await fs.readFile(path.join(repositoryRoot, relativePath), "utf8");
    assert.match(workflow, /^\s+jdk: "true"$/m, `${relativePath} must restore JDK downloads`);
    assert.match(workflow, /^\s+jdk-architecture: \$\{\{ matrix\.architecture \}\}$/m, `${relativePath} must cache the target architecture`);
  }

  const packageScript = await fs.readFile(path.join(repositoryRoot, "scripts/package-app.sh"), "utf8");
  assert.match(
    packageScript,
    /LITHE_ARCH="\$ARCH".*prepare-jdtls\.sh/,
    "macOS packages must validate JDTLS for the package architecture",
  );
  assert.match(
    packageScript,
    /LITHE_JDK_TARGET_ARCH="arm64"/,
    "universal macOS packages must prepare an ARM JDK",
  );
  assert.match(
    packageScript,
    /LITHE_JDK_TARGET_ARCH="x86_64"/,
    "universal macOS packages must prepare an Intel JDK",
  );
  assert.match(
    packageScript,
    /LanguageServers\/jdk-arm64/,
    "universal macOS packages must bundle the ARM JDK separately",
  );
  assert.match(
    packageScript,
    /LanguageServers\/jdk-x86_64/,
    "universal macOS packages must bundle the Intel JDK separately",
  );
  const previewScript = await fs.readFile(path.join(repositoryRoot, "scripts/preview.sh"), "utf8");
  assert.match(previewScript, /prepare-jdtls\.sh/, "macOS previews must prepare JDTLS");
  assert.match(previewScript, /prepare-jdk\.sh/, "macOS previews must prepare the bundled JDK");
  assert.match(
    previewScript,
    /Contents\/Resources\/LanguageServers\/jdtls/,
    "macOS previews must bundle JDTLS at the runtime lookup path",
  );
  assert.match(
    previewScript,
    /Contents\/Resources\/LanguageServers\/jdk/,
    "macOS previews must bundle the JDK at the runtime lookup path",
  );
  const prepareScript = await fs.readFile(path.join(repositoryRoot, "scripts/prepare-jdk.sh"), "utf8");
  assert.match(prepareScript, /TARGET_ARCH="\$\{LITHE_JDK_TARGET_ARCH:-\$\(uname -m\)\}"/);
  assert.match(prepareScript, /\.artifacts\/jdk-\$TARGET_ARCH/, "prepared macOS JDKs must be isolated by architecture");
  assert.match(prepareScript, /macos-aarch64/);
  assert.match(prepareScript, /macos-x86_64/);
  assert.match(prepareScript, /lipo.*-verify_arch.*TARGET_ARCH/, "macOS JDK validation must verify its Mach-O architecture");

  const packageVerifier = await fs.readFile(path.join(repositoryRoot, "scripts/verify-macos-package.sh"), "utf8");
  assert.match(
    packageVerifier,
    /env -u LITHE_ARCH/,
    "macOS package verification must exercise the default universal path",
  );
  assert.match(
    packageVerifier,
    /LanguageServers\/jdk-arm64\/bin\/java/,
    "macOS package verification must require the ARM JDK",
  );
  assert.match(
    packageVerifier,
    /LanguageServers\/jdk-x86_64\/bin\/java/,
    "macOS package verification must require the Intel JDK",
  );
}

try {
  await assertWindowsBunCacheConfiguration();
  await assertWindowsJavaToolingBuildConfiguration();
  await assertMacJdkCacheConfiguration();

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
  assertSucceeded(result);
  assert.equal(await fs.readFile(jdtlsArchive, "utf8"), "");
  await assert.rejects(fs.access(unexpected));
  assert.match(diagnostics(result), /not referenced by the JDTLS manifest/);

  const jdkCache = path.join(testRoot, "jdk-cache");
  const jdkManifest = path.join(testRoot, "jdk-manifest.json");
  const jdkArchive = path.join(jdkCache, `jdk-21.0.0-windows-x86_64-${emptySha256}.zip`);
  const macJdkArchive = path.join(jdkCache, `jdk-21.0.0-macos-aarch64-${emptySha256}.tar.gz`);
  const unexpectedJdk = path.join(jdkCache, "unexpected.download");
  await fs.mkdir(jdkCache, { recursive: true });
  await fs.writeFile(
    jdkManifest,
    JSON.stringify({
      version: "21.0.0",
      platforms: {
        "windows-x86_64": { sha256: emptySha256 },
        "macos-aarch64": { sha256: emptySha256 },
      },
    }),
  );
  await fs.writeFile(jdkArchive, "");
  await fs.writeFile(macJdkArchive, "");
  await fs.writeFile(unexpectedJdk, "unexpected");

  result = verify([
    "--cargo-cache",
    cargoCache,
    "--cargo-lock",
    cargoLock,
    "--jdk-cache",
    jdkCache,
    "--jdk-manifest",
    jdkManifest,
  ]);
  assertSucceeded(result);
  assert.equal(await fs.readFile(jdkArchive, "utf8"), "");
  assert.equal(await fs.readFile(macJdkArchive, "utf8"), "");
  await assert.rejects(fs.access(unexpectedJdk));
  assert.match(diagnostics(result), /not referenced by the JDK manifest/);

  await fs.writeFile(jdkArchive, "corrupted");
  result = verify([
    "--cargo-cache",
    cargoCache,
    "--cargo-lock",
    cargoLock,
    "--jdk-cache",
    jdkCache,
    "--jdk-manifest",
    jdkManifest,
  ]);
  assertSucceeded(result);
  await assert.rejects(fs.access(jdkArchive));
  assert.match(diagnostics(result), /JDK cache entry rejected.*SHA-256 mismatch/s);

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
