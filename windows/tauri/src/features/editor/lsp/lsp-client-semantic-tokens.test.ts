import { expect, spyOn, test } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient, type LspDocumentAvailability } from "./lsp-client";

const ready = {
  phase: "ready",
  languageId: "java",
  workspacePath: "C:/work",
  feature: "supported",
} as const;

test("semantic client invokes the Core adapter only for negotiated ready capabilities", async () => {
  const client = Object.create(LspClient.prototype) as LspClient;
  let availability: LspDocumentAvailability = ready;
  client.getDocumentAvailability = (_target, feature) => {
    expect(feature).toBe("semanticTokens");
    return availability;
  };
  const response = { tokenTypes: ["class"], tokenModifiers: [], tokens: [] };
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(response);
  try {
    const unsupported: LspDocumentAvailability[] = [
      { phase: "unavailable", languageId: "java" },
      {
        phase: "preparing",
        languageId: "java",
        workspacePath: "C:/work",
        sessionPhase: "initializing",
      },
      { ...ready, feature: "unknown" },
      { ...ready, feature: "unsupported" },
    ];
    for (const state of unsupported) {
      availability = state;
      expect(await client.getSemanticTokens("C:/work/Main.java")).toBeNull();
    }
    expect(invoke).not.toHaveBeenCalled();
    availability = ready;
    expect(await client.getSemanticTokens("C:/work/Main.java")).toEqual(response);
    expect(invoke).toHaveBeenCalledWith("lsp_get_semantic_tokens", {
      filePath: "C:/work/Main.java",
    });
    invoke.mockRejectedValue(Object.assign(new Error("Document changed"), { code: "cancelled" }));
    expect(await client.getSemanticTokens("C:/work/Main.java")).toBeNull();
  } finally {
    invoke.mockRestore();
  }
});
