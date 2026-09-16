import { installJavaTextMate } from "./textmate";

/** Bundlers resolve these standard asset/worker URLs into local application resources. */
export function installBundledJavaTextMate() {
  return installJavaTextMate({
    wasmURL: new URL("../node_modules/vscode-oniguruma/release/onig.wasm", import.meta.url).href,
    grammarURL: new URL("../vendor/java.tmLanguage.json", import.meta.url).href,
    createWorker: () => new Worker(new URL("./textmate-worker.ts", import.meta.url), { type: "module" }),
  });
}
