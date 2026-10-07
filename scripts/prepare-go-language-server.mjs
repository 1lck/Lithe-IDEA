#!/usr/bin/env node
// Build-time only. Go owns source/dependency verification and compilation; the
// plugin owns the resulting executable, license and immutable source identity.
import { readFile, mkdir, copyFile, mkdtemp, rm, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { runProcess } from "../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
async function run(command, args, options) {
  const result = await runProcess({ command, args, cwd: options.cwd, env: options.env, timeoutMs: options.timeout });
  if (result.code !== 0 || result.timedOut || !result.terminationConfirmed)
    throw new Error(`Plugin build command failed: ${result.stderr || result.signal || result.code}`);
  return result;
}
const root = fileURLToPath(new URL("../", import.meta.url));
const options = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, args) => {
  if (index % 2 === 0) pairs.push([value, args[index + 1]]);
  return pairs;
}, []));
const manifestPath = options["--manifest"] ?? path.join(root, "Plugins/mac/Official/GoSupport/language-server.json");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const output = options["--output"] ? path.resolve(options["--output"]) : undefined;
const target = options["--target"];
if (!output || !/^(darwin|windows|linux)-(amd64|arm64)$/.test(target ?? ""))
  throw new Error("Use --output directory --target darwin|windows|linux-amd64|arm64");
if (manifest.archiveFormat !== "goModuleZip" || !/^[a-f0-9]{64}$/.test(manifest.archiveSHA256)
  || manifest.archiveRoot !== `golang.org/x/tools/gopls@v${manifest.version}`
  || manifest.archiveURL !== `https://proxy.golang.org/golang.org/x/tools/gopls/@v/v${manifest.version}.zip`)
  throw new Error("Invalid pinned gopls source");
const cache = path.join(root, ".artifacts/plugin-tools");
const [os, arch] = target.split("-");
const env = { ...process.env, CGO_ENABLED: "0", GOTOOLCHAIN: "local",
  GOMODCACHE: path.join(cache, "go-module-cache"), GOCACHE: path.join(cache, "go-build", target),
  GOPROXY: "https://proxy.golang.org", GOSUMDB: "sum.golang.org" };
const go = process.env.LITHE_GO_EXECUTABLE ?? "go";
const downloaded = JSON.parse((await run(go, ["mod", "download", "-json", manifest.archiveRoot], {
  cwd: root, env, timeout: 300_000, maxBuffer: 1024 * 1024,
})).stdout);
if (downloaded.Error || !downloaded.Zip || !downloaded.Dir) throw new Error(downloaded.Error ?? "Go returned no verified module");
const digest = createHash("sha256").update(await readFile(downloaded.Zip)).digest("hex");
if (digest !== manifest.archiveSHA256) throw new Error("gopls source checksum mismatch");
// Compile verified archive bytes, not a possibly modified extracted module cache.
const sourceRoot = await mkdtemp(path.join(cache, "gopls-source-"));
try {
  await run(process.platform === "win32" ? "tar" : "unzip",
    process.platform === "win32" ? ["-xf", downloaded.Zip, "-C", sourceRoot] : ["-q", downloaded.Zip, "-d", sourceRoot],
    { cwd: root, env, timeout: 60_000 });
  const source = path.join(sourceRoot, manifest.archiveRoot);
  await run(go, ["mod", "download"], { cwd: source, env, timeout: 300_000 });
  await run(go, ["mod", "verify"], { cwd: source, env, timeout: 300_000 });
  const bin = path.join(output, "bin");
  await mkdir(bin, { recursive: true });
  await run(go, ["build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-o", path.join(bin, os === "windows" ? "gopls.exe" : "gopls"), "."], {
    cwd: source, env: { ...env, GOOS: os, GOARCH: arch }, timeout: 600_000,
  });
  await rm(path.join(output, "LICENSE"), { force: true });
  await copyFile(path.join(source, manifest.license), path.join(output, "LICENSE"));
  await copyFile(manifestPath, path.join(output, "language-server.json"));
  const licenses = path.join(output, "licenses");
  await rm(licenses, { recursive: true, force: true });
  // The module graph also contains unused/test-only modules without downloaded
  // sources. Distribute notices for the modules actually linked for this target.
  const modules = new Set((await run(go, ["list", "-mod=readonly", "-deps", "-f",
    "{{with .Module}}{{.Path}}\t{{.Version}}\t{{.Dir}}{{end}}", "."],
    { cwd: source, env: { ...env, GOOS: os, GOARCH: arch }, timeout: 60_000 }))
    .stdout.split("\n").map((line) => line.trim()).filter(Boolean));
  for (const module of modules) {
    const [name, version, directory] = module.split("\t");
    if (!directory) throw new Error(`Missing verified dependency source: ${name}`);
    const notices = (await readdir(directory, { withFileTypes: true }))
      .filter((entry) => entry.isFile() && /^(LICENSE|COPYING|NOTICE)([.-]|$)/i.test(entry.name));
    if (!notices.length) throw new Error(`Missing distribution license: ${name}`);
    const destination = path.join(licenses, encodeURIComponent(`${name}@${version || manifest.version}`));
    await mkdir(destination, { recursive: true });
    for (const notice of notices) await copyFile(path.join(directory, notice.name), path.join(destination, notice.name));
  }
} finally { await rm(sourceRoot, { recursive: true, force: true }); }
