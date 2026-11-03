import { installJavaTextMate } from "./textmate";

/** Explicit URLs let Vite fingerprint each offline grammar and worker. */
export function basicTextMateResources(language: string) {
  const grammars: Record<string, string> = {
    makefile: new URL("../vendor/make.tmLanguage.json", import.meta.url).href,
    cmake: new URL("../vendor/cmake.tmLanguage.json", import.meta.url).href,
    groovy: new URL("../vendor/groovy.tmLanguage.json", import.meta.url).href,
  };
  return {
    wasmURL: new URL("../node_modules/vscode-oniguruma/release/onig.wasm", import.meta.url).href,
    grammarURL: grammars[language],
    createWorker: () => new Worker(new URL("./textmate-worker.ts", import.meta.url), { type: "module" }),
  };
}

/** Bundlers resolve these standard asset/worker URLs into local application resources. */
export function installBundledJavaTextMate() {
  return installJavaTextMate({
    wasmURL: new URL("../node_modules/vscode-oniguruma/release/onig.wasm", import.meta.url).href,
    grammarURL: new URL("../vendor/java.tmLanguage.json", import.meta.url).href,
    createWorker: () => new Worker(new URL("./textmate-worker.ts", import.meta.url), { type: "module" }),
  });
}
