import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  MANIFEST_FILE,
  PREAMBLE,
  SERVER_BINARY,
  SERVER_TARGETS,
  createProtocolReader,
  defaultRunnerFor,
  elfProblems,
  encodeFrame,
  formatSummaryMarkdown,
  inspectElf,
  manifestProblems,
  readPinnedCoreRevision,
  stdioHello,
  verifyArtifacts,
} from "./verify-remote-server-artifacts.mjs";

const X86_64 = "x86_64-unknown-linux-musl";
const AARCH64 = "aarch64-unknown-linux-musl";
const TEST_TIMEOUT_MS = 60_000;

// An ELF64 little-endian file with one PT_LOAD segment that maps the whole file at address 0,
// and, when asked for, a PT_INTERP segment and a PT_DYNAMIC table naming `needed`.
function syntheticElf({ machine = 62, type = 3, entry = 0x1000, interpreter = null, needed = [], dynamic = needed.length > 0 } = {}) {
  const headers = 1 + (interpreter === null ? 0 : 1) + (dynamic ? 1 : 0);
  let cursor = 64 + 56 * headers;
  const nameOffsets = [];
  let strings = "\0";
  for (const name of needed) {
    nameOffsets.push(strings.length);
    strings += `${name}\0`;
  }
  const stringTable = cursor;
  cursor += strings.length;
  const interpreterOffset = cursor;
  cursor += interpreter === null ? 0 : interpreter.length + 1;
  cursor = Math.ceil(cursor / 8) * 8;
  const entries = [...nameOffsets.map((offset) => [1n, BigInt(offset)]), [5n, BigInt(stringTable)], [0n, 0n]];
  const dynamicOffset = cursor;
  cursor += dynamic ? 16 * entries.length : 0;
  const file = Buffer.alloc(cursor);
  file.writeUInt32BE(0x7f454c46, 0);
  file[4] = 2;
  file[5] = 1;
  file[6] = 1;
  file.writeUInt16LE(type, 16);
  file.writeUInt16LE(machine, 18);
  file.writeUInt32LE(1, 20);
  file.writeBigUInt64LE(BigInt(entry), 24);
  file.writeBigUInt64LE(64n, 32);
  file.writeUInt16LE(64, 52);
  file.writeUInt16LE(56, 54);
  file.writeUInt16LE(headers, 56);
  let header = 64;
  const programHeader = (segmentType, offset, size) => {
    file.writeUInt32LE(segmentType, header);
    file.writeBigUInt64LE(BigInt(offset), header + 8);
    file.writeBigUInt64LE(BigInt(offset), header + 16);
    file.writeBigUInt64LE(BigInt(size), header + 32);
    header += 56;
  };
  programHeader(1, 0, cursor);
  file.write(strings, stringTable, "latin1");
  if (interpreter !== null) {
    programHeader(3, interpreterOffset, interpreter.length + 1);
    file.write(`${interpreter}\0`, interpreterOffset, "latin1");
  }
  if (dynamic) {
    programHeader(2, dynamicOffset, 16 * entries.length);
    entries.forEach(([tag, value], index) => {
      file.writeBigInt64LE(tag, dynamicOffset + 16 * index);
      file.writeBigUInt64LE(value, dynamicOffset + 16 * index + 8);
    });
  }
  return file;
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

function manifestFor(files, overrides = {}) {
  return {
    schemaVersion: 1,
    coreRevision: "a".repeat(40),
    coreWorktree: "clean",
    coreSource: "pinned",
    serverVersion: "9.8.7",
    rustc: "rustc 1.100.0 (0ef1bc386 2026-11-09)",
    profile: "release",
    artifacts: Object.entries(files).map(([target, bytes]) => ({
      target,
      path: `${target}/${SERVER_BINARY}`,
      size: bytes.length,
      sha256: sha256(bytes),
    })),
    ...overrides,
  };
}

// Stands in for lithe-remote-server: `node fake-server.mjs <mode> <binary> <flag>`. It reports
// the SHA-256 of <binary> and the architecture of the target directory <binary> is in.
const FAKE_SERVER = `
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
const [mode, binary, flag] = process.argv.slice(2);
const target = path.basename(path.dirname(binary));
const arch = mode === "wrong-arch" ? "riscv64" : target.split("-")[0];
const frame = (message) => {
  const payload = Buffer.from(JSON.stringify(message));
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(payload.length);
  return Buffer.concat([prefix, payload]);
};
if (mode === "not-installed") {
  process.stdout.write("Welcome to the fixture host\\n");
  process.stderr.write("sh: 1: lithe-remote-server: not found\\n");
  process.exit(127);
}
if (flag === "--identity") {
  const sha256 = createHash("sha256").update(readFileSync(binary)).digest("hex");
  process.stdout.write(JSON.stringify({ serverVersion: "9.8.7", protocolVersion: 1, sha256 }) + "\\n");
} else if (flag === "--version") {
  process.stdout.write("9.8.7\\n");
} else if (flag === "--stdio") {
  process.stdout.write("motd line before the protocol\\n");
  process.stdout.write(Buffer.from(${JSON.stringify(PREAMBLE.toString("latin1"))}, "latin1"));
  let input = Buffer.alloc(0);
  process.stdin.on("data", (chunk) => {
    input = Buffer.concat([input, chunk]);
    while (input.length >= 4 && input.length >= 4 + input.readUInt32BE(0)) {
      const length = input.readUInt32BE(0);
      const request = JSON.parse(input.subarray(4, 4 + length).toString("utf8"));
      input = input.subarray(4 + length);
      if (mode === "silent") {
        continue;
      }
      process.stdout.write(frame({ type: "event", event: "fixture.notice", params: {}, seq: 1 }));
      process.stdout.write(frame({
        type: "response",
        id: request.id,
        result: {
          protocolVersion: request.params.protocolVersion,
          serverVersion: "9.8.7",
          host: { os: "linux", arch, hostName: "fixture" },
          session: { persistent: false, resumed: false, nextResourceId: 1, lastEventSeq: 0 },
        },
      }));
    }
  });
  process.stdin.on("end", () => process.exit(0));
}
`;

async function withStage(files, callback, manifestOverrides = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lithe remote-server-"));
  try {
    for (const [target, bytes] of Object.entries(files)) {
      await mkdir(path.join(root, target));
      await writeFile(path.join(root, target, SERVER_BINARY), bytes, { mode: 0o755 });
    }
    await writeFile(path.join(root, MANIFEST_FILE), JSON.stringify(manifestFor(files, manifestOverrides)));
    const fakeServer = path.join(root, "fake-server.mjs");
    await writeFile(fakeServer, FAKE_SERVER);
    const runner = (mode) => () => ({
      how: `fixture ${mode}`,
      spawnArgs: (binary, flags) => ({ command: process.execPath, args: [fakeServer, mode, binary, ...flags] }),
    });
    return await callback({ root, runner });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

const staticTargets = () => ({
  [X86_64]: syntheticElf({ machine: 62, type: 3, dynamic: true }),
  [AARCH64]: syntheticElf({ machine: 183, type: 2 }),
});

test("a static-pie and a static executable pass the ELF checks", () => {
  const pie = inspectElf(syntheticElf({ machine: 62, type: 3, dynamic: true }));
  assert.deepEqual({ interpreter: pie.interpreter, needed: pie.needed }, { interpreter: null, needed: [] });
  assert.deepEqual(elfProblems(pie, X86_64), []);
  assert.deepEqual(elfProblems(inspectElf(syntheticElf({ machine: 183, type: 2 })), AARCH64), []);
});

test("a program interpreter, a needed library or another machine fails the ELF checks", () => {
  const interpreted = elfProblems(inspectElf(syntheticElf({ interpreter: "/lib/ld-musl-x86_64.so.1" })), X86_64);
  assert.match(interpreted.join("\n"), /program interpreter \/lib\/ld-musl-x86_64\.so\.1/);
  const needing = elfProblems(inspectElf(syntheticElf({ needed: ["libgcc_s.so.1", "libc.so"] })), X86_64);
  assert.match(needing.join("\n"), /needs libgcc_s\.so\.1, libc\.so/);
  const foreign = elfProblems(inspectElf(syntheticElf({ machine: 183 })), X86_64);
  assert.match(foreign.join("\n"), /ELF machine 183 is not x86_64 \(62\)/);
  const relocatable = elfProblems(inspectElf(syntheticElf({ type: 1, entry: 0 })), X86_64);
  assert.equal(relocatable.length, 2, relocatable.join("\n"));
});

test("a file that is not a complete ELF64 file is rejected", () => {
  assert.throws(() => inspectElf(Buffer.from("#!/bin/sh\necho lithe-remote-server\n".padEnd(80))), /not an ELF file/);
  assert.throws(() => inspectElf(syntheticElf({ interpreter: "/lib/ld.so" }).subarray(0, 100)), /outside the file/);
  const thirtyTwoBit = syntheticElf();
  thirtyTwoBit[4] = 1;
  assert.throws(() => inspectElf(thirtyTwoBit), /64-bit little-endian/);
});

test("the manifest must name each target once at its fixed path", () => {
  const files = staticTargets();
  assert.deepEqual(manifestProblems(manifestFor(files)), []);
  const traversal = manifestFor(files);
  traversal.artifacts[0].path = `../${SERVER_BINARY}`;
  assert.match(manifestProblems(traversal).join("\n"), /path of x86_64-unknown-linux-musl is "\.\.\/lithe-remote-server"/);
  assert.match(manifestProblems(manifestFor({ [X86_64]: files[X86_64] })).join("\n"), /no artifact for aarch64-unknown-linux-musl/);
  const unknown = manifestFor(files);
  unknown.artifacts.push({ ...unknown.artifacts[0], target: "x86_64-unknown-linux-gnu" });
  assert.match(manifestProblems(unknown).join("\n"), /no known target: "x86_64-unknown-linux-gnu"/);
  const twice = manifestFor(files);
  twice.artifacts.push({ ...twice.artifacts[1] });
  assert.match(manifestProblems(twice).join("\n"), /lists aarch64-unknown-linux-musl more than once/);
  assert.match(manifestProblems(manifestFor(files, { coreRevision: "main" })).join("\n"), /coreRevision is "main"/);
  assert.deepEqual(Object.keys(SERVER_TARGETS).sort(), [AARCH64, X86_64]);
});

test("the protocol reader skips noise before the preamble and reassembles split frames", () => {
  const reader = createProtocolReader();
  const stream = Buffer.concat([Buffer.from("banner\n"), PREAMBLE, encodeFrame({ type: "event", event: "a" }), encodeFrame({ type: "response", id: 1 })]);
  const messages = [];
  for (let offset = 0; offset < stream.length; offset += 5) {
    messages.push(...reader.push(stream.subarray(offset, offset + 5)));
  }
  assert.deepEqual(messages, [{ type: "event", event: "a" }, { type: "response", id: 1 }]);
  const noisy = createProtocolReader({ noiseLimit: 16 });
  assert.throws(() => noisy.push(Buffer.alloc(16 + PREAMBLE.length, "x")), /no protocol preamble within the first 16 bytes/);
  const oversized = createProtocolReader({ maxFrameBytes: 8 });
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(9);
  assert.throws(() => oversized.push(Buffer.concat([PREAMBLE, prefix])), /9 bytes exceeds the 8-byte limit/);
});

test("staged artifacts pass and a changed executable fails the hash check", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root, runner }) => {
    const passed = await verifyArtifacts({ stageDir: root, smoke: [X86_64, AARCH64], pinnedRevision: "a".repeat(40), runnerFor: runner("good") });
    assert.deepEqual(passed.problems, []);
    assert.deepEqual(passed.results.map((result) => result.smoke), ["passed (fixture good, protocol 1)", "passed (fixture good, protocol 1)"]);
    assert.match(formatSummaryMarkdown(passed), /\| `aarch64-unknown-linux-musl` \| \d[\d,]* B \(0\.00 MiB\) \|/);

    await writeFile(path.join(root, AARCH64, SERVER_BINARY), syntheticElf({ machine: 183, type: 2, entry: 0x2000 }), { mode: 0o755 });
    const changed = await verifyArtifacts({ stageDir: root, runnerFor: runner("good") });
    assert.match(changed.problems.join("\n"), /aarch64-unknown-linux-musl: its SHA-256 is [0-9a-f]{64}, not the manifest's/);
    assert.equal(changed.results[1].smoke, "not run");
  });
});

test("a missing smoke runner fails only when the smoke test is required", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root }) => {
    const runnerFor = (target) => defaultRunnerFor(target, { platform: "darwin" });
    const optional = await verifyArtifacts({ stageDir: root, runnerFor });
    assert.deepEqual(optional.problems, []);
    assert.equal(optional.results[0].smoke, "skipped: Linux executables do not run on darwin");
    const required = await verifyArtifacts({ stageDir: root, runnerFor, smoke: [X86_64, AARCH64] });
    assert.equal(required.problems.length, 2, required.problems.join("\n"));
  });
});

test("no smoke test runs when none is asked for, and the files are still checked", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root, runner }) => {
    const runnerFor = () => assert.fail("no target should be run");
    const none = await verifyArtifacts({ stageDir: root, runnerFor, smoke: [], pinnedRevision: "a".repeat(40) });
    assert.deepEqual(none.problems, []);
    assert.deepEqual(none.results.map((result) => result.smoke), ["not run here", "not run here"]);

    await writeFile(path.join(root, X86_64, SERVER_BINARY), syntheticElf({ machine: 62, type: 2, entry: 0x3000 }), { mode: 0o755 });
    const changed = await verifyArtifacts({ stageDir: root, runnerFor: runner("good"), smoke: [] });
    assert.match(changed.problems.join("\n"), /x86_64-unknown-linux-musl: its SHA-256 is [0-9a-f]{64}, not the manifest's/);
  });
});

test("only the named targets must pass the smoke test, and another architecture is never emulated", { timeout: TEST_TIMEOUT_MS }, async () => {
  assert.equal(defaultRunnerFor(X86_64, { platform: "linux", arch: "x64" }).how, "native");
  assert.equal(defaultRunnerFor(AARCH64, { platform: "linux", arch: "arm64" }).how, "native");
  assert.deepEqual(defaultRunnerFor(AARCH64, { platform: "linux", arch: "x64" }), { skipped: "it runs only on arm64 Linux, and this machine is x64" });
  await withStage(staticTargets(), async ({ root, runner }) => {
    const good = runner("good");
    // An x86_64 runner: the aarch64 executable is checked but cannot run.
    const runnerFor = (target) => (target === X86_64 ? good(target) : defaultRunnerFor(target, { platform: "linux", arch: "x64" }));
    const automatic = await verifyArtifacts({ stageDir: root, runnerFor });
    assert.deepEqual(automatic.problems, []);
    assert.deepEqual(automatic.results.map((result) => result.smoke), ["passed (fixture good, protocol 1)", "skipped: it runs only on arm64 Linux, and this machine is x64"]);
    const x86Only = await verifyArtifacts({ stageDir: root, runnerFor, smoke: [X86_64] });
    assert.deepEqual(x86Only.problems, []);
    assert.deepEqual(x86Only.results.map((result) => result.smoke), ["passed (fixture good, protocol 1)", "not run here"]);
    const both = await verifyArtifacts({ stageDir: root, runnerFor, smoke: [X86_64, AARCH64] });
    assert.deepEqual(both.problems, [`${AARCH64}: the smoke test is required but cannot run: it runs only on arm64 Linux, and this machine is x64`]);
  });
});

test("artifacts from a core override fail when the pin is required", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root }) => {
    const runnerFor = () => ({ skipped: "not needed" });
    const pinned = await verifyArtifacts({ stageDir: root, runnerFor, pinnedRevision: "b".repeat(40) });
    assert.match(pinned.problems.join("\n"), /not a clean checkout of the pinned b{40}/);
  }, { coreSource: "override" });
});

test("the pinned core revision is read from build-desktop-core.sh", async () => {
  assert.match(await readPinnedCoreRevision(), /^[0-9a-f]{40}$/);
});

test("a server that is not installed fails the handshake with its exit and output", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root, runner }) => {
    const binary = path.join(root, X86_64, SERVER_BINARY);
    await assert.rejects(
      stdioHello(runner("not-installed")().spawnArgs(binary, ["--stdio"]), { protocolVersion: 1, arch: "x86_64", serverVersion: "9.8.7" }),
      (error) => {
        assert.match(error.message, /exited with exit code 127 while waiting for the protocol preamble/);
        assert.match(error.message, /Welcome to the fixture host/);
        assert.match(error.message, /lithe-remote-server: not found/);
        return true;
      },
    );
  });
});

test("a handshake reporting another architecture fails", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root, runner }) => {
    const binary = path.join(root, AARCH64, SERVER_BINARY);
    await assert.rejects(
      stdioHello(runner("wrong-arch")().spawnArgs(binary, ["--stdio"]), { protocolVersion: 1, arch: "aarch64", serverVersion: "9.8.7" }),
      /reports the architecture "riscv64", not aarch64/,
    );
  });
});

test("a server that never answers is stopped at the deadline", { timeout: TEST_TIMEOUT_MS }, async () => {
  await withStage(staticTargets(), async ({ root, runner }) => {
    const binary = path.join(root, X86_64, SERVER_BINARY);
    await assert.rejects(
      stdioHello(runner("silent")().spawnArgs(binary, ["--stdio"]), { protocolVersion: 1, arch: "x86_64", serverVersion: "9.8.7", timeoutMs: 500 }),
      /no answer within 500 ms while waiting for the server\.hello response/,
    );
  });
});
