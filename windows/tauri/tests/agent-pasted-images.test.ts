import { beforeEach, describe, expect, mock, test } from "bun:test";

const fixture = await Bun.file(new URL("../../../shared/fixtures/agent/attachment-retention-v1.json", import.meta.url)).json();
const writes: string[] = [];
const removals: string[] = [];
const invocations: { command: string; args: any }[] = [];
const listing: { name: string; isFile: boolean }[] = [];
const modified = new Map<string, number>();
const files = new Map<string, string>();
let failWrite = 0;
let failRemove = false;
const retentionCase = (name: string) => fixture.cases.find((item: any) => item.name === name);
let planCase: any = retentionCase("mixed cache keeps order within each list");
mock.module("@tauri-apps/api/path", () => ({ appCacheDir: async () => "C:/cache", join: async (...parts: string[]) => parts.join("/") }));
mock.module("@tauri-apps/plugin-fs", () => ({
  mkdir: async () => {},
  exists: async (path: string) => files.has(path) || writes.includes(path),
  readDir: async () => listing,
  readTextFile: async (path: string) => files.get(path) ?? "[]",
  writeTextFile: async (path: string, text: string) => { files.set(path, text); },
  rename: async (from: string, to: string) => { files.set(to, files.get(from)!); files.delete(from); },
  stat: async (path: string) => ({ mtime: new Date(modified.get(path) ?? Date.now()) }),
  writeFile: async (path: string) => { writes.push(path); if (writes.length === failWrite) throw new Error("write refused"); },
  remove: async (path: string) => { removals.push(path); if (failRemove && removals.length === 1) throw new Error("remove refused"); },
}));
// Core stand-in: the first sweep returns the shared fixture's mixed-cache answer; later
// calls only carry abandoned pastes, which the fixture's "abandoned" rule deletes at once.
mock.module("../src/platform/tauri-core", () => ({
  invoke: async (command: string, args: any) => {
    invocations.push({ command, args });
    if (args.entries.length > 0 && args.entries.every((entry: any) => entry.abandoned)) {
      return { delete: args.entries.map((entry: any) => ({ path: entry.path, reason: "abandoned" })), keep: [] };
    }
    const local = (path: string) => args.entries.find((entry: any) => entry.path.endsWith(path.slice(2))).path;
    const place = (items: any[]) => items.map((item) => ({ ...item, path: local(item.path) }));
    return args.entries.length === 0
      ? { delete: [], keep: [], seed: [] }
      : { delete: place(planCase.expected.delete), keep: place(planCase.expected.keep), seed: planCase.expected.seed.map(local) };
  },
}));
const { savePastedImages, recordAcceptedPastedImages } = await import("../src/platform/agent-pasted-images");
const image = () => new File([new Uint8Array(4)], "sample.png", { type: "image/png" });
beforeEach(() => {
  writes.length = 0; removals.length = 0; invocations.length = 0; listing.length = 0; modified.clear(); files.clear();
  failWrite = 0; failRemove = false;
});
describe("Agent pasted image storage", () => {
  test("the first use sweeps the cache with the Core plan and the accepted ledger", async () => {
    const root = "C:/cache/agent/pasted-images";
    const now = Date.now();
    for (const [name, days] of [["1.png", 30], ["2.png", 30], ["3.png", 2], ["4.png", 9]] as const) {
      listing.push({ name, isFile: true });
      modified.set(`${root}/${name}`, now - days * 86_400_000);
    }
    listing.push({ name: "folder", isFile: false });
    files.set("C:/cache/agent/pasted-images-accepted.json", JSON.stringify([`${root}/2.png`]));
    await savePastedImages([image()]);
    expect(invocations[0].command).toBe("agent.attachments.retentionPlan");
    expect(invocations[0].args.acceptedReferences).toEqual([`${root}/2.png`]);
    expect(invocations[0].args.caseInsensitive).toBe(true);
    expect(invocations[0].args.entries.map((entry: any) => entry.path)).toEqual(["1", "2", "3", "4"].map((n) => `${root}/${n}.png`));
    expect(invocations[0].args.entries.every((entry: any) => entry.abandoned === false)).toBe(true);
    expect(removals).toEqual([`${root}/1.png`, `${root}/4.png`]);
  });
  // A fresh module instance repeats the once-per-process first sweep.
  const freshSweep = async (caseName: string, ledger: string | null) => {
    const root = "C:/cache/agent/pasted-images";
    planCase = retentionCase(caseName);
    for (const entry of planCase.request.entries) {
      listing.push({ name: entry.path.slice(3), isFile: true });
      modified.set(`${root}/${entry.path.slice(3)}`, planCase.request.nowMs - 30 * 86_400_000);
    }
    if (ledger !== null) files.set("C:/cache/agent/pasted-images-accepted.json", ledger);
    const module = await import(`../src/platform/agent-pasted-images?${caseName}`);
    await module.savePastedImages([image()]);
    return root;
  };
  test("a missing ledger seeds the existing images and deletes nothing", async () => {
    const root = await freshSweep("missing ledger seeds every cached image and keeps old ones", null);
    expect(invocations[0].args.ledgerPresent).toBe(false);
    expect(removals).toEqual([]);
    expect(JSON.parse(files.get("C:/cache/agent/pasted-images-accepted.json")!)).toEqual([`${root}/old.png`, `${root}/new.png`]);
    expect(files.has("C:/cache/agent/pasted-images-accepted.json.tmp")).toBe(false);
  });
  test("an existing empty ledger never migrates again", async () => {
    const root = await freshSweep("empty ledger that exists does not migrate again", "[]");
    expect(invocations[0].args.ledgerPresent).toBe(true);
    expect(removals).toEqual([`${root}/old.png`]);
    expect(files.get("C:/cache/agent/pasted-images-accepted.json")).toBe("[]");
  });
  test("an accepted prompt records only cached images in the ledger", async () => {
    const root = "C:/cache/agent/pasted-images";
    files.set("C:/cache/agent/pasted-images-accepted.json", "[]");
    files.set(`${root}/5.png`, "x");
    files.set("C:/other/6.png", "x");
    await recordAcceptedPastedImages([`file:///${root}/5.png`, "file:///C:/other/6.png", "file:///C:/cache/agent/pasted-images/gone.png"]);
    expect(JSON.parse(files.get("C:/cache/agent/pasted-images-accepted.json")!)).toEqual([`${root}/5.png`]);
  });
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
