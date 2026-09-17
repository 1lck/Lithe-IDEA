import { resolve, join } from "node:path";
import { buildEditorAssets } from "../../frontend/editor/build";

const root = resolve(import.meta.dir, "../..");
await buildEditorAssets({
  entrypoint: join(import.meta.dir, "main.ts"),
  html: join(import.meta.dir, "index.html"),
  output: join(root, ".artifacts/editor/macos"),
  entryName: "workbench",
  textmate: true,
});
