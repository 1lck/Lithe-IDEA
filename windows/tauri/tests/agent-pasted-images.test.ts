import { beforeEach, describe, expect, mock, test } from "bun:test";

const writes: string[] = [];
const removals: string[] = [];
let failWrite = 0;
let failRemove = false;
mock.module("@tauri-apps/api/path", () => ({ appCacheDir: async () => "C:/cache", join: async (...parts: string[]) => parts.join("/") }));
mock.module("@tauri-apps/plugin-fs", () => ({
  mkdir: async () => {},
  writeFile: async (path: string) => { writes.push(path); if (writes.length === failWrite) throw new Error("write refused"); },
  remove: async (path: string) => { removals.push(path); if (failRemove && removals.length === 1) throw new Error("remove refused"); },
}));
const { savePastedImages } = await import("../src/platform/agent-pasted-images");
const image = () => new File([new Uint8Array(4)], "sample.png", { type: "image/png" });
beforeEach(() => { writes.length = 0; removals.length = 0; failWrite = 0; failRemove = false; });
describe("Agent pasted image storage", () => {
  test("accepted files stay in the application cache until their owner discards them", async () => {
    const batch = await savePastedImages([image(), image()]);
    expect(batch.paths).toEqual(writes);
    expect(batch.paths.every((path) => path.startsWith("C:/cache/agent/pasted-images/pasted-") && path.endsWith(".png"))).toBe(true);
    expect(new Set(batch.paths).size).toBe(2);
    await batch.discard();
    expect(removals).toEqual(batch.paths);
  });
  test("invalid type, single-file size, count and batch size fail before any write", async () => {
    for (const files of [[new File(["x"], "x.txt", { type: "text/plain" })],
      [new File([new Uint8Array(10 * 1024 * 1024 + 1)], "x.png", { type: "image/png" })],
      Array.from({ length: 33 }, image),
      Array.from({ length: 4 }, () => new File([new Uint8Array(9 * 1024 * 1024)], "x.png", { type: "image/png" })),
    ]) await expect(savePastedImages(files)).rejects.toThrow();
    expect(writes).toHaveLength(0);
  });
  test("a partial write failure attempts cleanup of every owned file", async () => {
    failWrite = 2;
    await expect(savePastedImages([image(), image(), image()])).rejects.toThrow("write refused");
    expect(removals).toEqual(writes);
    expect(removals).toHaveLength(2);
  });
  test("one cleanup failure does not prevent cleanup of the remaining files", async () => {
    const batch = await savePastedImages([image(), image()]);
    failRemove = true;
    await expect(batch.discard()).rejects.toThrow("agent.composer.imageCleanupFailed");
    expect(removals).toEqual(batch.paths);
  });
});
