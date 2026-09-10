import { beforeEach, describe, expect, mock, test } from "bun:test";

let response = { bytes: [] as number[], truncated: false };
const invoke = mock(async (_command: string, _args?: unknown) => response);
mock.module("./tauri-core", () => ({ invoke }));
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
