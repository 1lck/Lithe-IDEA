/** Build an independently imported package; this is never part of the app build. */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const plugin = path.join(root, "Plugins/win/Official/PhpSupport");
const result = await Bun.build({
  entrypoints: [path.join(plugin, "plugin.ts")],
  target: "browser",
  format: "esm",
  minify: false,
});
if (!result.success) throw new Error(result.logs.join("\n"));
const source = await result.outputs[0].text();
const manifest = JSON.parse(await readFile(path.join(plugin, "plugin.json"), "utf8"));
const output = path.join(root, ".artifacts/windows-plugins");
await mkdir(output, { recursive: true });
const bytes = JSON.stringify({ format: "lithe-worker-plugin", version: 1, manifest, source });
const destination = path.join(output, `${manifest.id}-${manifest.version}.lithe-extension`);
await writeFile(destination, bytes);
console.log(destination);
