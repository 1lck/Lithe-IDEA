import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as core from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/diff/compare-texts-v1.json";
import { createLocalHistoryDiff, type TextComparison } from "./local-history-diff";

const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath
  ? dlopen(libraryPath, {
      lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
      lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
    })
  : null;
afterAll(() => library?.close());

let restore: (() => void) | undefined;
afterEach(() => {
  restore?.();
  restore = undefined;
});

function serveFixture() {
  const invoke = spyOn(core, "invoke").mockImplementation((async (command, args) => {
    expect(command).toBe("diff.compareTexts");
    const { oldText, newText } = args as { oldText: string; newText: string };
    const item = fixture.cases.find((entry) => entry.oldText === oldText && entry.newText === newText);
    if (!item) throw new Error("unexpected comparison");
    return item.expected;
  }) as typeof core.invoke);
  restore = () => invoke.mockRestore();
}

for (const item of fixture.cases) {
  test(`local history renders the shared comparison: ${item.name}`, async () => {
    serveFixture();
    const expected = item.expected as TextComparison;
    const diff = await createLocalHistoryDiff({
      filePath: "C:/work/src/main.txt",
      oldContent: item.oldText,
      newContent: item.newText,
    });
    expect(diff.file_path).toBe("main.txt");
    expect(diff.additions).toBe(expected.additions);
    expect(diff.deletions).toBe(expected.deletions);
    // The unified view keeps Core's order: each block lists removals before additions.
    expect(diff.lines.slice(1).map((line) => [line.line_type, line.content])).toEqual(
      expected.lines.map((line) => [line.kind, line.content]),
    );
    // The split view uses Core's similarity pairing instead of re-pairing locally.
    expect(diff.split_hunks?.flat().map((row) => [row.kind, row.old_line_number ?? null, row.new_line_number ?? null]))
      .toEqual(expected.rows.map((row) => [row.kind, row.oldLine, row.newLine]));
  });
}

test("line-ending-only changes produce an empty comparison", async () => {
  serveFixture();
  const diff = await createLocalHistoryDiff({
    filePath: "notes.txt",
    oldContent: "alpha\r\nbeta\r\n",
    newContent: "alpha\nbeta",
  });
  expect(diff.additions).toBe(0);
  expect(diff.deletions).toBe(0);
  expect(diff.split_hunks?.flat().every((row) => row.kind === "context")).toBe(true);
});

for (const item of fixture.cases) {
  test.skipIf(!library)(`native Core diff.compareTexts matches the fixture: ${item.name}`, async () => {
    const invoke = spyOn(core, "invoke").mockImplementation((async (command, payload) => {
      const input = Buffer.from(JSON.stringify({ id: "diff", command, payload }) + "\0");
      const pointer = library!.symbols.lithe_core_execute_json(input);
      if (!pointer) throw new Error("Core returned null");
      try {
        const response = JSON.parse(new CString(pointer).toString());
        if (!response.ok) throw new Error(response.error.message);
        return response.data;
      } finally {
        library!.symbols.lithe_core_free_string(pointer);
      }
    }) as typeof core.invoke);
    restore = () => invoke.mockRestore();
    const { compareTexts } = await import("./local-history-diff");
    expect(await compareTexts(item.oldText, item.newText)).toEqual(item.expected as TextComparison);
  });
}
