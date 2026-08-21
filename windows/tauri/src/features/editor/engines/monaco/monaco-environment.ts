import { editor as monacoEditor } from "monaco-editor";
import {
  openExternalBrowserUrl,
  resolveExternalBrowserUrl,
} from "@/features/window/utils/external-navigation";

declare global {
  interface Window {
    MonacoEnvironment?: {
      getWorker: (_workerId: string, label: string) => Worker;
    };
    __litheMonacoContextMenuInitialized?: boolean;
    __litheMonacoExternalLinkOpenerInitialized?: boolean;
  }
}

if (typeof window !== "undefined") {
  if (!window.__litheMonacoExternalLinkOpenerInitialized) {
    window.__litheMonacoExternalLinkOpenerInitialized = true;
    monacoEditor.registerLinkOpener({
      open: (resource) => {
        const url = resolveExternalBrowserUrl(resource.toString(true));
        if (!url) return false;

        void openExternalBrowserUrl(url);
        return true;
      },
    });
  }

  if (!window.__litheMonacoContextMenuInitialized) {
    window.__litheMonacoContextMenuInitialized = true;
    for (const editor of monacoEditor.getEditors()) {
      editor.updateOptions({ contextmenu: false });
    }
    monacoEditor.onDidCreateEditor((editor) => {
      editor.updateOptions({ contextmenu: false });
    });
  }

  window.MonacoEnvironment = {
    getWorker: (_workerId, label) => {
      // Construct workers on demand so the TypeScript worker chunk is not
      // fetched until a JS/TS file actually needs it.
      if (label === "json") {
        return new Worker(
          new URL("monaco-editor/esm/vs/language/json/json.worker.js", import.meta.url),
          { type: "module" },
        );
      }
      if (label === "css" || label === "scss" || label === "less") {
        return new Worker(
          new URL("monaco-editor/esm/vs/language/css/css.worker.js", import.meta.url),
          { type: "module" },
        );
      }
      if (label === "html" || label === "handlebars" || label === "razor") {
        return new Worker(
          new URL("monaco-editor/esm/vs/language/html/html.worker.js", import.meta.url),
          { type: "module" },
        );
      }
      if (label === "typescript" || label === "javascript") {
        return new Worker(
          new URL("monaco-editor/esm/vs/language/typescript/ts.worker.js", import.meta.url),
          { type: "module" },
        );
      }
      return new Worker(new URL("monaco-editor/esm/vs/editor/editor.worker.js", import.meta.url), {
        type: "module",
      });
    },
  };
}
