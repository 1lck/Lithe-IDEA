import { resolve, join } from "node:path";
import { buildEditorAssets } from "../../../frontend/editor/build";

const root = resolve(import.meta.dir, "../../..");
const workbench = process.argv.includes("--workbench");
const tests = process.argv.includes("--workbench-tests");
const host = join(root, "macos/EditorFrontend");
await buildEditorAssets({
  entrypoint: tests ? join(import.meta.dir, "workbench.integration.ts")
    : workbench ? join(host, "main.ts") : join(import.meta.dir, "editor.ts"),
  html: join(workbench || tests ? host : import.meta.dir, "index.html"),
  output: join(root, tests ? ".artifacts/monaco-workbench/test-assets"
    : workbench ? ".artifacts/monaco-workbench/assets" : ".artifacts/monaco-probe/assets"),
  entryName: workbench || tests ? "workbench" : "editor",
  textmate: workbench || tests,
  monaco: process.argv[2],
  worker: workbench || tests ? undefined : join(import.meta.dir, "worker.ts"),
});
