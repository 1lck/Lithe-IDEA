import { expect, mock, test } from "bun:test";
import type * as Monaco from "monaco-editor";
import fixture from "../../../../../../../shared/fixtures/lsp/semantic-tokens-v1.json";
import { registerLspDocumentChangeFlusher } from "@/features/editor/lsp/pending-document-changes";
import type { LspSemanticTokensResponse } from "@/features/editor/lsp/semantic-token-types";
import { createMonacoSemanticTokenProvider } from "./semantic-token-provider";

function harness() {
  const state = {
    version: 1,
    disposed: false,
    open: true,
    active: true,
    eligible: true,
    cancelled: false,
    path: "C:/work/Main.java",
  };
  const model = {
    uri: { toString: () => "file:///C:/work/Main.java" },
    getVersionId: () => state.version,
    isDisposed: () => state.disposed,
    getLineCount: () => 3,
    getLineMaxColumn: () => 30,
  } as unknown as Monaco.editor.ITextModel;
  const token = {
    get isCancellationRequested() {
      return state.cancelled;
    },
  } as Monaco.CancellationToken;
  const request = mock(
    async (): Promise<LspSemanticTokensResponse | null> => fixture.expectedResult,
  );
  const provider = createMonacoSemanticTokenProvider({
    client: {
      getActiveServerEntryForFile: () => (state.active ? {} : null),
      isDocumentOpen: () => state.open,
      getSemanticTokens: request,
    },
    filePathFromModel: () => state.path,
    isLspModel: () => state.eligible,
  });
  return {
    state,
    request,
    provide: () => provider.provideDocumentSemanticTokens(model, null, token),
  };
}

test("flushes pending text before requesting colors and maps the shared Core fixture to Monaco", async () => {
  const h = harness();
  let flushed = false;
  const unregister = registerLspDocumentChangeFlusher(h.state.path, async () => {
    flushed = true;
  });
  h.request.mockImplementation(async () => {
    expect(flushed).toBe(true);
    return fixture.expectedResult;
  });
  try {
    const result = (await h.provide()) as Monaco.languages.SemanticTokens;
    // Server legend indices class=0/method=1 become Monaco class=2/method=13.
    expect([...result.data]).toEqual([0, 6, 5, 2, 0, 2, 4, 3, 13, 0, 0, 7, 2, 13, 0]);
  } finally {
    unregister();
  }
});

for (const change of ["cancelled", "disposed", "version", "open", "path", "eligible"] as const) {
  test(`discards a response after the model's ${change} changes`, async () => {
    const h = harness();
    h.request.mockImplementation(async () => {
      if (change === "version") h.state.version++;
      else if (change === "path") h.state.path = "C:/work/Other.java";
      else if (change === "open" || change === "eligible") h.state[change] = false;
      else h.state[change] = true;
      return fixture.expectedResult;
    });
    expect(await h.provide()).toBeNull();
  });
}

for (const unavailable of ["active", "open", "eligible", "cancelled"] as const) {
  test(`does not request colors when ${unavailable} prevents highlighting`, async () => {
    const h = harness();
    h.state[unavailable] = unavailable === "cancelled";
    expect(await h.provide()).toBeNull();
    expect(h.request).not.toHaveBeenCalled();
  });
}

test("does not request colors if the model changes during document synchronization", async () => {
  const h = harness();
  const unregister = registerLspDocumentChangeFlusher(h.state.path, async () => {
    h.state.version++;
  });
  try {
    expect(await h.provide()).toBeNull();
    expect(h.request).not.toHaveBeenCalled();
  } finally {
    unregister();
  }
});

test("keeps basic highlighting available when Core returns no semantic colors", async () => {
  const h = harness();
  h.request.mockResolvedValue(null);
  expect(await h.provide()).toBeNull();
});
