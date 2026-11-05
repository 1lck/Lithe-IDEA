import { afterAll, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/keymap/binding-conflicts-v1.json";
import {
  assertNoKeybindingConflicts,
  KeybindingConflictError,
} from "./binding-conflicts";
import { keymapRegistry } from "./registry";

const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath
  ? dlopen(libraryPath, {
      lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
      lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
    })
  : null;
afterAll(() => library?.close());

function callCore(command: string, payload: unknown) {
  const input = Buffer.from(JSON.stringify({ id: "conflicts", command, payload }) + "\0");
  const pointer = library!.symbols.lithe_core_execute_json(input);
  if (!pointer) throw new Error("Core returned null");
  try {
    const response = JSON.parse(new CString(pointer).toString());
    if (!response.ok) throw new Error(response.error.message);
    return response.data;
  } finally {
    library!.symbols.lithe_core_free_string(pointer);
  }
}

for (const item of fixture.cases.filter((candidate) => candidate.platform === "windows")) {
  test.skipIf(!library)(`native Core keymap conflicts: ${item.name}`, () => {
    expect(callCore("keymap.analyzeConflicts", { platform: item.platform, layers: item.layers })).toEqual(
      item.expected,
    );
  });
}

test.skipIf(!library)("a save that collides with a default is rejected before it is stored", async () => {
  const invoke = spyOn(native, "invoke").mockImplementation((async (command: string, payload: unknown) =>
    callCore(command, payload)) as typeof native.invoke);
  const registry = spyOn(keymapRegistry, "getAllKeybindings").mockReturnValue([
    { key: "ctrl+d", command: "default.only", source: "default" },
  ]);
  try {
    await expect(
      assertNoKeybindingConflicts(
        {
          preset: "none",
          registryKeybindings: keymapRegistry.getAllKeybindings(),
          userKeybindings: [{ key: "Ctrl+D", command: "user.new", source: "user", enabled: true }],
        },
        ["user.new"],
      ),
    ).rejects.toEqual(expect.any(KeybindingConflictError));
    await expect(
      assertNoKeybindingConflicts(
        {
          preset: "none",
          registryKeybindings: keymapRegistry.getAllKeybindings(),
          userKeybindings: [{ key: "ctrl+e", command: "user.new", source: "user", enabled: true }],
        },
        ["user.new"],
      ),
    ).resolves.toBeUndefined();
  } finally {
    registry.mockRestore();
    invoke.mockRestore();
  }
});
