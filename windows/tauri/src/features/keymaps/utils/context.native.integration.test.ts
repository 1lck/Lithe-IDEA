import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/keymap/context-v1.json";
import {
  evaluateWhenClause,
  prepareWhenClause,
  releasePreparedContexts,
  type ParsedContext,
} from "./context";
import { parseKeybindingsImportJson } from "./keybinding-import-export";

const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath
  ? dlopen(libraryPath, {
      lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
      lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
    })
  : null;
afterAll(() => library?.close());
afterEach(() => releasePreparedContexts());

for (const item of fixture.cases) {
  test.skipIf(!library)(
    `native Core context -> import and synchronous dispatch: ${item.name}`,
    async () => {
      const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
        const input = Buffer.from(JSON.stringify({ id: "context", command, payload }) + "\0");
        const pointer = library!.symbols.lithe_core_execute_json(input);
        if (!pointer) throw new Error("Core returned null");
        try {
          const response = JSON.parse(new CString(pointer).toString());
          if (!response.ok) throw new Error(response.error.message);
          return response.data;
        } finally {
          library!.symbols.lithe_core_free_string(pointer);
        }
      });
      try {
        const expression = item.expression;
        if ("error" in item) {
          await expect(prepareWhenClause(expression)).rejects.toMatchObject({ code: item.error });
          await expect(
            parseKeybindingsImportJson(
              JSON.stringify([
                { key: "ctrl+k", command: "test.action", when: expression, source: "user" },
              ]),
            ),
          ).rejects.toMatchObject({ code: item.error });
          expect(evaluateWhenClause(expression, {})).toBe(false);
        } else {
          await prepareWhenClause(expression);
          const context = item.context as Record<string, boolean>;
          const calls = invoke.mock.calls.length;
          expect(evaluateWhenClause(expression, context)).toBe(item.matches);
          expect(invoke).toHaveBeenCalledTimes(calls);
          const result = await native.invoke<{ parsed: ParsedContext }>("keymap.parseContext", {
            expression,
          });
          const evaluated = await native.invoke<{ matches: boolean }>("keymap.evaluateContext", {
            parsed: result.parsed,
            context,
          });
          expect(evaluated.matches).toBe(item.matches);
        }
      } finally {
        invoke.mockRestore();
      }
    },
  );
}
