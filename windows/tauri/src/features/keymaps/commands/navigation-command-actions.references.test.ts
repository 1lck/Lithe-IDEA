import { expect, spyOn, test } from "bun:test";
import { editorAPI } from "@/features/editor/extensions/api";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useReferencesStore } from "@/features/references/stores/references.store";
import { useSpringStore } from "@/features/spring/stores/spring.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { goToReferences } from "./navigation-command-actions";

test("find references retains distinct locations on the current line", async () => {
  const filePath = "C:/work/Main.java";
  const content = "name = name + name";
  const ranges = [0, 7, 14].map((character) => ({
    uri: "file:///C:/work/Main.java",
    range: { start: { line: 0, character }, end: { line: 0, character: character + 4 } },
  }));
  const client = {
    getDocumentAvailability: () => ({ phase: "ready", feature: "supported" }),
    getReferences: async () => ranges,
  } as unknown as LspClient;
  const restorers = [
    spyOn(LspClient, "getInstance").mockReturnValue(client),
    spyOn(useBufferStore, "getState").mockReturnValue({
      activeBufferId: "a", buffers: [{ id: "a", type: "editor", path: filePath, content }],
    } as unknown as ReturnType<typeof useBufferStore.getState>),
    spyOn(useSpringStore, "getState").mockReturnValue({ root: null } as unknown as ReturnType<typeof useSpringStore.getState>),
    spyOn(editorAPI, "getCursorPosition").mockReturnValue({ line: 0, column: 1, offset: 1 }),
    spyOn(editorAPI, "getContent").mockReturnValue(content),
  ];
  try {
    await goToReferences();
    expect(useReferencesStore.getState().references.map(({ line, column }) => ({ line, column })))
      .toEqual([{ line: 0, column: 0 }, { line: 0, column: 7 }, { line: 0, column: 14 }]);
  } finally {
    for (const restorer of restorers) restorer.mockRestore();
    useReferencesStore.getState().actions.clear();
    useUIState.getState().setIsReferencesPopoverVisible(false);
  }
}, 1000);
