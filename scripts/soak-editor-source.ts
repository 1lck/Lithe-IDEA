// Diagnostic soak, not a machine-dependent CI heap threshold. Run with pinned Bun.
import { heapStats } from "bun:jsc";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const modulePath = process.env.LITHE_SOURCE_TEXT_MODULE;
const { SourceText } = await import(modulePath ? pathToFileURL(resolve(modulePath)).href : "../frontend/editor/src/source-text");
const normalized = (text: string) => text.replace(/\r\n|\r/g, "\n");
function sample() {
  Bun.gc(true);
  const heap = heapStats();
  return { heapBytes: heap.heapSize, objects: heap.objectCount, rssBytes: process.memoryUsage().rss };
}
function run(scenario: "linear" | "branch" | "replace") {
  const original = "original\r\n中😀\rline\n".repeat(32768);
  const source = new SourceText(original, 1);
  let native = original;
  let version = 1;
  const before = sample();
  const started = performance.now();
  function edit(text: string, alternativeVersion: number) {
    const changes = source.apply([{ rangeOffset: 0, rangeLength: normalized(native).length, text: normalized(text) }], alternativeVersion);
    for (const change of [...changes].sort((a, b) => b.offset - a.offset)) {
      native = native.slice(0, change.offset) + change.text + native.slice(change.offset + change.length);
    }
    if (native !== source.value) throw new Error("Incremental native mirror diverged during soak");
  }
  for (let index = 0; index < 100; index++) {
    if (scenario === "linear") {
      const changes = source.apply([{ rangeOffset: 0, rangeLength: 0, text: String(index) }], ++version);
      for (const change of changes) native = native.slice(0, change.offset) + change.text + native.slice(change.offset + change.length);
    } else {
      // Distinct 128 KiB replacements exercise retained payloads, not just the
      // small path copies of ordinary typing in the persistent tree.
      const block = (`replacement-${index}\r\n中😀\n`).repeat(8192).slice(0, 131072);
      if (scenario === "replace") { source.replace(block, ++version); native = block; }
      else edit(block, ++version);
      edit(original, 1);
      if (native !== original) throw new Error("Undo lost original newline bytes");
      // Monaco increments versionId during undo before giving the branch a new ID.
      version++;
    }
  }
  // End each abandoned branch with a fresh edit, as Monaco discards redo only
  // on that edit. An undo by itself must leave the redo root reachable.
  const changes = source.apply([{ rangeOffset: 0, rangeLength: 0, text: "final" }], ++version);
  for (const change of changes) native = native.slice(0, change.offset) + change.text + native.slice(change.offset + change.length);
  const after = sample();
  if (native !== source.value) throw new Error("Final source mirror diverged");
  edit(original, 1);
  if (native !== original) throw new Error("Oldest undo was evicted");
  return { scenario, cycles: 100, initialUTF16Length: original.length,
    elapsedMs: Math.round(performance.now() - started), before, after,
    retainedHeapGrowthBytes: after.heapBytes - before.heapBytes };
}

console.log(JSON.stringify({ bun: Bun.version, results: [run("linear"), run("branch"), run("replace")] }, null, 2));
