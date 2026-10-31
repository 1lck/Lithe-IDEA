import { expect, test } from "bun:test";
import { watchBuildConfiguration, type BuildConfigurationCheck } from "./build-configuration-watch";
import { DocumentWatchInputs } from "@/platform/document-watch-inputs";

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(complete => { resolve = complete; }); return { promise, resolve }; }
// A native read/registration settles through this fixed promise chain.
async function flush() { for (let index = 0; index < 12; index++) await Promise.resolve(); }

test("source leases register aliases once, verify after registration and ignore unchanged own writes", async () => {
  const inputs = new DocumentWatchInputs(); let reads = 0, changes = 0, current = true;
  const watch = watchBuildConfiguration(async () => { reads++; return { current, paths: ["C:/user/settings.xml", "c:\\USER\\settings.xml", "\\\\?\\C:\\user\\settings.xml"] }; }, () => { changes++; }, inputs);
  try {
    await flush(); const source = inputs.snapshot()[0]!; expect(inputs.snapshot()).toHaveLength(1); expect(source.path).toBe("C:/user/settings.xml"); expect(reads).toBe(1);
    source.registered(true); await flush(); expect(reads).toBe(2);
    source.changed(); await flush(); expect(changes).toBe(0);
    current = false; source.changed(); await flush(); expect(changes).toBe(1);
  } finally { await watch.dispose(); }
  expect(inputs.snapshot()).toEqual([]);
}, 5000);

test("early rechecks wait for attachment and a retargeted alias expires even with identical bytes", async () => {
  const inputs = new DocumentWatchInputs(), initial = deferred<BuildConfigurationCheck>(); let reads = 0, changes = 0;
  let paths = ["C:/alias/settings.xml", "C:/old/settings.xml"];
  const watch = watchBuildConfiguration(async () => { reads++; return reads === 1 ? await initial.promise : { current: true, paths }; }, () => { changes++; }, inputs);
  try {
    watch.recheck(); expect(reads).toBe(1);
    initial.resolve({ current: true, paths }); await flush(); expect(reads).toBe(1);
    inputs.snapshot().forEach(input => input.registered(true)); await flush(); expect(reads).toBe(2); expect(changes).toBe(0);
    paths = ["C:/alias/settings.xml", "C:/new/settings.xml"]; watch.recheck(); await flush();
    expect(changes).toBe(1);
  } finally { initial.resolve({ current: true, paths: [] }); await watch.dispose(); }
}, 5000);

test("retirement drains an initial native read without registering its late paths", async () => {
  const inputs = new DocumentWatchInputs(), reply = deferred<BuildConfigurationCheck>(); let changed = 0, closed = false;
  const watch = watchBuildConfiguration(() => reply.promise, () => { changed++; }, inputs);
  const closing = watch.dispose().then(() => { closed = true; });
  try {
    await flush(); expect(closed).toBe(false);
    reply.resolve({ current: false, paths: ["C:/user/private.xml"] }); await closing;
    expect(changed).toBe(0); expect(inputs.snapshot()).toEqual([]);
  } finally { reply.resolve({ current: true, paths: [] }); await closing; }
}, 5000);

test("a pending registration can be retired and failed attachment invalidates its baseline", async () => {
  const inputs = new DocumentWatchInputs(); let changes = 0;
  const create = () => watchBuildConfiguration(async () => ({ current: true, paths: ["C:/user/settings.xml"] }), () => { changes++; }, inputs);
  const pending = create(); await flush();
  await pending.dispose(); expect(changes).toBe(0);
  const failed = create();
  try { await flush(); inputs.snapshot()[0]!.registered(false); await flush(); expect(changes).toBe(1); }
  finally { await failed.dispose(); }
}, 5000);

test("a burst coalesces native reads and retirement drains a late recheck", async () => {
  const inputs = new DocumentWatchInputs(), reply = deferred<BuildConfigurationCheck>(); let reads = 0, changes = 0;
  const watch = watchBuildConfiguration(async () => { reads++; return reads <= 2 ? { current: true, paths: ["C:/user/settings.xml"] } : await reply.promise; }, () => { changes++; }, inputs);
  let closing: Promise<void> | undefined;
  try {
    await flush(); inputs.snapshot()[0]!.registered(true); await flush();
    for (let index = 0; index < 100; index++) watch.recheck();
    expect(reads).toBe(3); closing = watch.dispose();
    reply.resolve({ current: false, paths: [] }); await closing;
    expect(reads).toBe(3); expect(changes).toBe(0);
  } finally { reply.resolve({ current: true, paths: [] }); await closing; await watch.dispose(); }
}, 5000);
