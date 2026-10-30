import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (_command: string, _args?: unknown) =>
  JSON.stringify({ ok: true, data: { root: { path: "" }, files: ["src/a.ts", "src/b.ts"] } }),
);
// Mock the Tauri boundary, not the Core client: a module mock is process-wide in Bun,
// and replacing the client would hide the real request builder from later test files.
// Spread the native module so re-exported names (isTauri, transformCallback) keep
// resolving for anything else that loads through @/platform/tauri-core.
const nativeCore = await import("@tauri-apps/api/core");
mock.module("@tauri-apps/api/core", () => ({
  ...nativeCore,
  invoke: (command: string, args?: unknown) => invoke(command, args),
}));
const { fffListFiles } = await import("./file-search-api");

beforeEach(() => invoke.mockClear());

describe("workspace file listing", () => {
  test("asks Core for the flat file list only, never the full node tree", async () => {
    const files = await fffListFiles(["C:/work/project"]);

    expect(files.map((file) => file.relative_path)).toEqual(["src/a.ts", "src/b.ts"]);
    expect(invoke).toHaveBeenCalledTimes(1);
    const [command, args] = invoke.mock.calls[0] as [string, { request: string }];
    expect(command).toBe("core_execute");
    const request = JSON.parse(args.request);
    expect(request.command).toBe("workspace.snapshot");
    expect(request.payload).toEqual({ root: "C:/work/project", includeTree: false });
  });
});
