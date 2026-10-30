// Build the GPUI terminal island.
//
// Unlike gpui/editor this host needs no Monaco; it bundles main.ts (plus the
// xterm stylesheet main.ts imports) into a single IIFE and copies the HTML
// shell. Output: dist/index.html, dist/terminal.js, dist/terminal.css.
//
// Run from the repository root after `bun install`:
//   bun gpui/terminal/build.ts

import { join } from "node:path";
import { copyFile, mkdir, rm } from "node:fs/promises";
import type { BunPlugin } from "bun";

interface PackageManifest {
  module?: string;
  main?: string;
  style?: string;
}

const hostRoot = import.meta.dir;
const repoRoot = join(hostRoot, "..", "..");
const outputDir = join(hostRoot, "dist");

// @xterm is installed by the Windows Tauri workspace, so Bun's isolated
// install may leave no resolvable link in the repository root. Probe the
// node_modules directories Bun may have linked, including the nested package
// directory, instead of relying on a single hoisted location.
const NODE_MODULE_DIRS = [
  join(hostRoot, "node_modules"),
  join(repoRoot, "windows", "tauri", "node_modules"),
  join(repoRoot, "frontend", "editor", "node_modules"),
  join(repoRoot, "gpui", "editor", "node_modules"),
  join(repoRoot, "gpui", "node_modules"),
  join(repoRoot, "node_modules"),
];

async function packageDirectory(specifier: string): Promise<string> {
  for (const nodeModules of NODE_MODULE_DIRS) {
    const directory = join(nodeModules, ...specifier.split("/"));
    if (await Bun.file(join(directory, "package.json")).exists()) return directory;
  }
  throw new Error(`Cannot resolve ${specifier}; run \`bun install\` in the repository root.`);
}

async function manifestOf(directory: string): Promise<PackageManifest> {
  return (await Bun.file(join(directory, "package.json")).json()) as PackageManifest;
}

function moduleEntry(directory: string, manifest: PackageManifest, label: string): string {
  const relative = typeof manifest.module === "string" ? manifest.module : manifest.main;
  if (typeof relative !== "string" || !relative) {
    throw new Error(`${label} does not declare a module or main entry`);
  }
  return join(directory, relative);
}

const xtermDir = await packageDirectory("@xterm/xterm");
const fitDir = await packageDirectory("@xterm/addon-fit");
const xtermManifest = await manifestOf(xtermDir);
const fitManifest = await manifestOf(fitDir);

const xtermEntry = moduleEntry(xtermDir, xtermManifest, "@xterm/xterm");
const fitEntry = moduleEntry(fitDir, fitManifest, "@xterm/addon-fit");
const xtermCss = join(xtermDir, typeof xtermManifest.style === "string" ? xtermManifest.style : "css/xterm.css");

// Map only the specifiers main.ts imports; xterm's published bundles are
// self-contained, so no other package resolution is overridden.
const xtermPlugin: BunPlugin = {
  name: "explicit-xterm-packages",
  setup(builder) {
    builder.onResolve({ filter: /^@xterm\/xterm$/ }, () => ({ path: xtermEntry }));
    builder.onResolve({ filter: /^@xterm\/xterm\/css\/xterm\.css$/ }, () => ({ path: xtermCss }));
    builder.onResolve({ filter: /^@xterm\/addon-fit$/ }, () => ({ path: fitEntry }));
  },
};

// Rebuild dist from scratch so a failed CSS extraction cannot be masked by a
// stylesheet left over from an earlier run.
await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });

const result = await Bun.build({
  entrypoints: [join(hostRoot, "main.ts")],
  outdir: outputDir,
  target: "browser",
  format: "iife",
  minify: true,
  naming: "terminal.[ext]",
  plugins: [xtermPlugin],
});

if (!result.success) {
  throw new AggregateError(result.logs, "Failed to bundle gpui/terminal");
}

// index.html links these exact names; fail the build instead of shipping a
// page that silently loads no script or stylesheet.
for (const required of ["terminal.js", "terminal.css"]) {
  if (!(await Bun.file(join(outputDir, required)).exists())) {
    throw new Error(`Bun did not emit ${required} in ${outputDir}`);
  }
}

await copyFile(join(hostRoot, "index.html"), join(outputDir, "index.html"));
console.log(`Terminal assets written to ${outputDir}`);
