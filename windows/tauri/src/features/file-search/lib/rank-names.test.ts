import { afterAll, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/search/rank-names-v1.json";
import { rankNames, type RankNameCandidate } from "./rank-names";

test("blank queries and empty inventories never cross the native boundary", async () => {
  const invoke = spyOn(native, "invoke");
  try {
    expect(await rankNames("  ", [{ name: "a.ts" }])).toEqual([]);
    expect(await rankNames("a", [])).toEqual([]);
    expect(invoke).not.toHaveBeenCalled();
  } finally {
    invoke.mockRestore();
  }
});

test("the request carries names, explicit context and the per-tier limit", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue({ matches: [] } as never);
  try {
    await rankNames("dh", [{ name: "DeviceHandler.java", path: "src/DeviceHandler.java" }], {
      openPaths: ["src/DeviceHandler.java"],
    }, 5);
    expect(invoke).toHaveBeenCalledWith("workspace.rankNames", {
      query: "dh",
      candidates: [{ name: "DeviceHandler.java", path: "src/DeviceHandler.java" }],
      context: { openPaths: ["src/DeviceHandler.java"], recentPaths: [] },
      limitPerTier: 5,
    });
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
  test.skipIf(!library)(`native Core name ranking: ${item.id}`, async () => {
    const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
      const input = Buffer.from(JSON.stringify({ id: "rank", command, payload }) + "\0");
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
      const request = item.request as {
        query: string;
        candidates: RankNameCandidate[];
        context?: { openPaths?: string[]; recentPaths?: string[] };
        limitPerTier?: number;
      };
      const ranked = await rankNames(
        request.query,
        request.candidates,
        request.context,
        request.limitPerTier,
      );
      expect(
        ranked.map((hit) => ({ index: hit.index, tier: hit.tier, ranges: hit.nameMatchRanges })),
      ).toEqual(item.expected as never);
    } finally {
      invoke.mockRestore();
    }
  });
}
