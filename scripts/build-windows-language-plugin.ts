/** Build a signed package containing worker code and pinned language-server files. */
import { mkdir, readFile, readdir, writeFile, cp, rm, mkdtemp } from "node:fs/promises";
import { createHash, createPrivateKey, createPublicKey, sign, randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { runProcess } from "../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const pluginName = process.argv[2];
const target = process.argv[3] ?? "windows-x86_64";
if (!["PhpSupport", "GoSupport"].includes(pluginName) || !["windows-x86_64", "windows-aarch64"].includes(target))
  throw new Error("Use PhpSupport|GoSupport windows-x86_64|windows-aarch64");
const testOnly = process.argv.includes("--test-signature");
const privateBytes = process.env.LITHE_PLUGIN_PACKAGE_PRIVATE_KEY ?? (testOnly ? randomBytes(32).toString("base64") : undefined);
if (!privateBytes) throw new Error("Set LITHE_PLUGIN_PACKAGE_PRIVATE_KEY to build an installable signed language plugin");
const seed = Buffer.from(privateBytes, "base64");
if (seed.length !== 32) throw new Error("Plugin signing key must contain 32 bytes");
const key = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
const publicKey = createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
const publisher = JSON.parse(await readFile(path.join(root, "shared/contracts/plugin-publisher.json"), "utf8"));
const officialKey = publisher.publicKeyBase64;
if (publicKey !== officialKey && !testOnly) throw new Error("Signing key does not match the official publisher key");
const plugin = path.join(root, "Plugins/win/Official", pluginName);
const manifest = JSON.parse(await readFile(path.join(plugin, "plugin.json"), "utf8"));
manifest.nativeTarget = target;
const output = path.join(root, ".artifacts/windows-plugins");
await mkdir(output, { recursive: true });
const staging = await mkdtemp(path.join(output, ".staging-"));
async function run(command: string, args: string[], timeoutMs: number) {
  const result = await runProcess({ command, args, cwd: root, env: process.env, timeoutMs });
  if (result.code !== 0 || result.timedOut || !result.terminationConfirmed) throw new Error(result.stderr || "Plugin build failed");
}
try {
  const built = await Bun.build({ entrypoints: [path.join(plugin, "plugin.ts")], target: "browser", format: "esm" });
  if (!built.success) throw new Error(built.logs.join("\n"));
  await writeFile(path.join(staging, "plugin.js"), await built.outputs[0].text());
  if (pluginName === "GoSupport") {
    await run("node", [path.join(root, "scripts/prepare-go-language-server.mjs"),
      "--manifest", path.join(plugin, "language-server.json"),
      "--output", path.join(staging, "resources/go"),
      "--target", target === "windows-x86_64" ? "windows-amd64" : "windows-arm64"], 900_000);
  } else {
    const metadataPath = path.join(plugin, "language-server.json");
    const metadata = JSON.parse(await readFile(metadataPath, "utf8"));
    if (metadata.archiveFormat !== "tarGzip" || !metadata.archiveURL.startsWith("https://")) throw new Error("Invalid pinned PHP archive");
    const response = await fetch(metadata.archiveURL, { signal: AbortSignal.timeout(120_000) });
    if (!response.ok) throw new Error(`PHP archive download failed: ${response.status}`);
    const chunks: Uint8Array[] = [];
    let length = 0;
    if (!response.body) throw new Error("PHP archive body is missing");
    const reader = response.body.getReader();
    try {
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        length += next.value.length;
        if (length > 64 * 1024 * 1024) throw new Error("PHP archive exceeds 64 MB");
        chunks.push(next.value);
      }
    } finally { await reader.cancel(); }
    const archive = Buffer.concat(chunks);
    if (createHash("sha256").update(archive).digest("hex") !== metadata.archiveSHA256) throw new Error("PHP archive checksum mismatch");
    const archivePath = path.join(staging, "intelephense.tgz");
    const extracted = path.join(staging, "extract");
    await mkdir(extracted);
    await writeFile(archivePath, archive);
    await run("tar", ["-xzf", archivePath, "-C", extracted], 60_000);
    await mkdir(path.join(staging, "resources/php"), { recursive: true });
    await cp(path.join(extracted, metadata.archiveRoot), path.join(staging, "resources/php/package"), { recursive: true });
    await cp(metadataPath, path.join(staging, "resources/php/language-server.json"));
    await rm(extracted, { recursive: true });
    await rm(archivePath);
  }
  await writeFile(path.join(staging, "plugin.json"), JSON.stringify(manifest));
  const files: Record<string, string> = {};
  const hashes: Record<string, string> = {};
  async function collect(directory: string) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) await collect(file);
      else {
        if (!entry.isFile()) throw new Error("Plugin packages cannot contain symlinks");
        const bytes = await readFile(file);
        const relative = path.relative(staging, file).split(path.sep).join("/");
        files[relative] = bytes.toString("base64");
        hashes[relative] = createHash("sha256").update(bytes).digest("hex");
      }
    }
  }
  await collect(staging);
  const token = (value: string) => Buffer.from(value).toString("base64url");
  const payload = ["schemaVersion=1", "algorithm=ed25519", "keyID=lithe-official-plugins-v1",
    `pluginID=${token(manifest.id)}`, `pluginVersion=${token(manifest.version)}`,
    ...Object.keys(hashes).sort().map((file) => `file=${token(file)}=${hashes[file]}`)].join("\n") + "\n";
  const document = { schemaVersion: 1, algorithm: "ed25519", keyID: "lithe-official-plugins-v1",
    pluginID: manifest.id, pluginVersion: manifest.version, files: hashes,
    signature: sign(null, Buffer.from(payload), key).toString("base64") };
  const destination = path.join(output, `${manifest.id}-${manifest.version}-${target}${testOnly ? ".test-signed" : ""}.lithe-extension`);
  await writeFile(destination, JSON.stringify({ format: "lithe-native-worker-plugin", version: 1, files, signature: document }));
  console.log(destination);
} finally { await rm(staging, { recursive: true, force: true }); }
