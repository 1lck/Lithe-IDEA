import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

let response = { bytes: [] as number[], truncated: false };
const invoke = mock(async (_command: string, _args?: unknown) => response);
// Keep the real router and Tauri module graph. Stub only the native IPC entry;
// replacing the API module drops exports imported by indirect dependencies.
const originalWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
Object.defineProperty(globalThis, "window", { configurable: true, value: {
  __TAURI_INTERNALS__: { invoke: (command: string, args?: unknown) => invoke(command, args) },
} });
afterAll(() => {
  if (originalWindow) Object.defineProperty(globalThis, "window", originalWindow);
  else Reflect.deleteProperty(globalThis, "window");
});
const { readGitPatchFile, writeGitPatchFile } = await import("./git-patch-files");

beforeEach(() => {
  invoke.mockClear();
  response = { bytes: [], truncated: false };
});

describe("Patch file bytes", () => {
  test("preserves valid UTF-8, BOM, and CRLF without a lossy decoding fallback", async () => {
    const patch = "\uFEFFdiff --git a/示例.txt b/示例.txt\r\n";
    response.bytes = [...new TextEncoder().encode(patch)];
    expect(await readGitPatchFile("C:/example.patch")).toBe(patch);
    await writeGitPatchFile("C:/saved.patch", patch);
    expect(invoke).toHaveBeenLastCalledWith("write_patch_file", {
      path: "C:/saved.patch",
      contents: patch,
    });
  });

  test("rejects malformed UTF-8 and bounded-read truncation before Core sees partial text", async () => {
    response.bytes = [0xff];
    await expect(readGitPatchFile("C:/invalid.patch")).rejects.toThrow("git.patch.invalidUtf8");
    response = { bytes: [], truncated: true };
    await expect(readGitPatchFile("C:/large.patch")).rejects.toThrow("git.patch.fileTooLarge");
  });
});
