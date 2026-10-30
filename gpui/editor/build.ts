import { join } from "node:path";
import { buildEditorAssets } from "../../frontend/editor/build";

// Reuse the shared Monaco build; this host only supplies its own entrypoint,
// HTML shell and output directory. No TextMate worker: the GPUI frontend uses
// Monarch tokenizers only and does not link an LSP.
await buildEditorAssets({
  entrypoint: join(import.meta.dir, "main.ts"),
  html: join(import.meta.dir, "index.html"),
  output: join(import.meta.dir, "dist"),
  entryName: "editor",
  textmate: false,
});
