import { afterAll, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/workspace/entry-order-v1.json";
import { orderFileEntries, partitionDirectoriesFirst } from "./entry-order";

type FixtureCase = (typeof fixture.cases)[number];
const byId = (id: string): FixtureCase => fixture.cases.find((entry) => entry.id === id)!;
const toFileEntries = (item: FixtureCase) =>
  item.request.entries.map((entry) => ({ name: entry.name, path: `C:/w/${entry.name}`, isDir: entry.isDirectory }));

// Replays Core's answer for the mixed-kind fixture case, pinning the request
// shape and the permutation handling without a native library.
const fixtureInvoke = (async (command: string, payload?: unknown) => {
  expect(command).toBe("workspace.orderEntries");
  const mixed = byId("name-order-mixes-directories-and-files");
  expect(payload).toEqual({ entries: mixed.request.entries, directoriesFirst: false });
  const names = mixed.request.entries.map((entry) => entry.name);
  return { order: mixed.orderedNames.map((name) => names.indexOf(name)) };
}) as typeof native.invoke;

test("tree children use Core's name order and folders-first is only a stable partition", async () => {
  const invoke = spyOn(native, "invoke").mockImplementation(fixtureInvoke);
  try {
    const mixed = byId("name-order-mixes-directories-and-files");
    const ordered = await orderFileEntries(toFileEntries(mixed));
    expect(ordered.map((entry) => entry.name)).toEqual(mixed.orderedNames);
    expect(partitionDirectoriesFirst(ordered).map((entry) => entry.name)).toEqual(
      byId("directories-first-is-the-default").orderedNames,
    );
  } finally {
    invoke.mockRestore();
  }
});

test("single entries never cross the native boundary", async () => {
  const invoke = spyOn(native, "invoke");
  try {
    const entries = [{ name: "only", path: "C:/w/only", isDir: false }];
    expect(await orderFileEntries(entries)).toEqual(entries);
    expect(invoke).not.toHaveBeenCalled();
  } finally {
    invoke.mockRestore();
  }
});

const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath
  ? dlopen(libraryPath, {
      lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
      lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
    })
  : null;
afterAll(() => library?.close());

for (const item of fixture.cases) {
  test.skipIf(!library)(`native Core entry order: ${item.id}`, async () => {
    const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
      const input = Buffer.from(JSON.stringify({ id: "order", command, payload }) + "\0");
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
      const ordered = await orderFileEntries(toFileEntries(item));
      const displayed =
        item.request.directoriesFirst === false ? ordered : partitionDirectoriesFirst(ordered);
      expect(displayed.map((entry) => entry.name)).toEqual(item.orderedNames);
    } finally {
      invoke.mockRestore();
    }
  });
}
