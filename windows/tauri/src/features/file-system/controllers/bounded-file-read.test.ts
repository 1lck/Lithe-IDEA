import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (_command: string, _args?: unknown): Promise<unknown> => null);

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { readFileWithinByteLimit } = await import("./bounded-file-read");

beforeEach(() => invoke.mockReset());

describe("readFileWithinByteLimit", () => {
  test("passes the byte limit to the native bounded-read command", async () => {
    invoke.mockResolvedValue({
      bytes: Array.from(new TextEncoder().encode("class App {}")),
      truncated: false,
    });

    await expect(readFileWithinByteLimit("C:/workspace/App.java", 256 * 1024)).resolves.toBe(
      "class App {}",
    );
    expect(invoke).toHaveBeenCalledWith("read_local_file_bounded", {
      path: "C:/workspace/App.java",
      maxBytes: 256 * 1024,
    });
  });

  test("does not decode truncated or oversized host payloads", async () => {
    invoke.mockResolvedValue({ bytes: [0x63, 0x6c, 0x61, 0x73], truncated: true });
    await expect(readFileWithinByteLimit("C:/workspace/App.java", 4)).resolves.toBeNull();

    invoke.mockResolvedValue({ bytes: [0x63, 0x6c, 0x61, 0x73, 0x73], truncated: false });
    await expect(readFileWithinByteLimit("C:/workspace/App.java", 4)).resolves.toBeNull();
  });

  test("rejects invalid UTF-8 without exposing it to semantic parsing", async () => {
    invoke.mockResolvedValue({ bytes: [0xff], truncated: false });

    await expect(readFileWithinByteLimit("C:/workspace/App.java", 4)).resolves.toBeNull();
  });
});
