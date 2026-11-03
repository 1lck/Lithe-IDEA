import { afterAll, describe, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/lsp/text-edits-v1.json";
import { applyTextEditsToContent } from "./workspace-edit";

// Explicit native integration lane: use a locally built Core library, never an
// installed app or a network service. Unit tests do not require this artifact.
const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath ? dlopen(libraryPath, {
  lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
  lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
}) : null;
afterAll(() => library?.close());

describe("Windows text edits through the native Core ABI", () => {
  for (const item of fixture.cases) {
    test.skipIf(!library)(item.name, async () => {
      const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
        const input = Buffer.from(JSON.stringify({ id: "text-edits", command, payload }) + "\0");
        const pointer = library!.symbols.lithe_core_execute_json(input);
        if (!pointer) throw new Error("Core returned a null response pointer");
        try {
          const response = JSON.parse(new CString(pointer).toString());
          if (!response.ok) throw Object.assign(new Error(response.error.message), response.error);
          return response.data;
        } finally { library!.symbols.lithe_core_free_string(pointer); }
      });
      try {
        if ("expectedError" in item) {
          await expect(applyTextEditsToContent(item.text, item.edits)).rejects.toMatchObject({
            code: "invalid_request", details: item.expectedError,
          });
        } else {
          expect(await applyTextEditsToContent(item.text, item.edits)).toBe(item.expectedText);
        }
      } finally { invoke.mockRestore(); }
    });
  }
});
