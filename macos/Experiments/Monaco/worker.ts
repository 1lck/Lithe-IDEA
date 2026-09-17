import { start } from "monaco-editor/esm/vs/editor/editor.worker.start.js";

// Real Monaco worker RPC and mirror models, not a synthetic echo worker.
start((context: any) => ({
  inspect() {
    return context.getMirrorModels().map((model: any) => ({
      uri: model.uri.toString(), length: model.getValue().length,
    }));
  },
}));
