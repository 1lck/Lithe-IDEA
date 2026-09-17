// Shared editor resource build. Native adapters and integration hosts supply entrypoints.
import { join, resolve } from "node:path";
import { mkdir, copyFile, writeFile, realpath } from "node:fs/promises";
import type { BunPlugin } from "bun";

const editorRoot = import.meta.dir;

export interface EditorAssetBuild {
  entrypoint: string;
  html: string;
  output: string;
  entryName: string;
  textmate: boolean;
  monaco?: string;
  worker?: string;
}

/** Hosts choose their entrypoint and destination; shared builds own dependency assets. */
export async function buildEditorAssets(options: EditorAssetBuild): Promise<void> {
  const { output } = options;
  // Bun workspace dependencies can be symlinks. Canonicalize before resolving
  // package imports so direct and relative imports share one Monaco registry.
  const monaco = await realpath(resolve(options.monaco ?? join(editorRoot, "node_modules/monaco-editor")));
  const version = (await Bun.file(join(monaco, "package.json")).json()).version;
  const manifest = await Bun.file(join(editorRoot, "package.json")).json();
  if (manifest.dependencies["monaco-editor"] !== version) {
    throw new Error("Installed Monaco must match the shared editor's exact pinned version");
  }
  await mkdir(output, { recursive: true });
  const plugin: BunPlugin = {
    name: "explicit-monaco-package",
    setup(builder) {
      builder.onResolve({ filter: /^@lithe\/editor\// }, args => ({ path: join(editorRoot, "src", args.path.slice("@lithe/editor/".length) + ".ts") }));
      builder.onResolve({ filter: /^monaco-editor\// }, (args) => ({
        path: join(monaco, args.path.slice("monaco-editor/".length)),
      }));
    },
  };
  const entries = [
    { name: "worker", path: options.worker ?? join(editorRoot, "src/worker.ts") },
    ...(options.textmate ? [{ name: "textmate-worker", path: join(editorRoot, "src/textmate-worker.ts") }] : []),
    { name: options.entryName, path: options.entrypoint },
  ];
  for (const entry of entries) {
    const result = await Bun.build({
      entrypoints: [entry.path],
      outdir: output, target: "browser", format: "iife", minify: true,
      plugins: [plugin], naming: `${entry.name}.[ext]`,
    });
    if (!result.success) throw new AggregateError(result.logs, `Failed to bundle ${entry.name}`);
  }
  await copyFile(options.html, join(output, "index.html"));
  await copyFile(join(monaco, "LICENSE"), join(output, "MONACO-LICENSE.txt"));
  await writeFile(join(output, "version.json"), JSON.stringify({ monaco: version, bun: Bun.version }));
  console.log(`Monaco ${version}: ${output}`);

  if (options.textmate) {
    for (const [source, target] of [
      ["node_modules/vscode-oniguruma/release/onig.wasm", "onig.wasm"],
      ["vendor/java.tmLanguage.json", "java.tmLanguage.json"],
      ["vendor/LICENSE.vscode.txt", "VSCODE-LICENSE.txt"],
      ["vendor/NOTICE.txt", "TEXTMATE-NOTICE.txt"],
      ["node_modules/vscode-oniguruma/LICENSE.txt", "ONIGURUMA-LICENSE.txt"],
      ["node_modules/vscode-textmate/LICENSE.md", "TEXTMATE-LICENSE.md"],
    ]) await copyFile(join(editorRoot, source), join(output, target));
  }
}
