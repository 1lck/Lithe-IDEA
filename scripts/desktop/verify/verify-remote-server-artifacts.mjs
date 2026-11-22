#!/usr/bin/env node
// Checks the remote workspace server executables that scripts/desktop/build-remote-server.sh
// staged, and reports their sizes.
//
// Usage: node scripts/desktop/verify/verify-remote-server-artifacts.mjs
//            [--stage <dir>] [--smoke <target>|all|none]... [--require-pinned]
//
// From the manifest and the files alone, for every target of SERVER_TARGETS:
// - the manifest names exactly these targets, each at <target>/lithe-remote-server;
// - the file is a regular executable file whose size and SHA-256 match the manifest;
// - it is an ELF64 executable for the target's machine and statically linked: it has neither a
//   program interpreter nor a DT_NEEDED entry, so it runs on any Linux host or container of
//   that architecture, whatever C library it has.
//
// On Linux of a target's own architecture, a smoke test also runs that executable.
// `--identity` must report the manifest's version and SHA-256, and `--version` the same
// version. A `--stdio` session must answer `server.hello` for the target's architecture and
// end when standard input closes. Executables of another architecture are never run under an
// emulator: a pass there would not show that they work on the hardware they ship to, so CI
// builds every target on one runner and then tests each on a runner of its own architecture.
//
// Flags:
//   --smoke <target>|all|none
//                      smoke test only this target, every target, or none. A named target must
//                      run and pass here; the others are checked but reported as not run here.
//                      Repeat it to name several targets. Without it, every target this machine
//                      can run is smoke tested and the others are reported as skipped.
//   --require-pinned   fail unless the artifacts come from a clean checkout of the core revision
//                      that scripts/desktop/build-desktop-core.sh pins.
//
// Sizes go to standard output and to the GitHub step summary, and never fail the check:
// security and features come before size (#2231, D9).
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, lstat, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SERVER_BINARY = "lithe-remote-server";
export const MANIFEST_FILE = "remote-server-manifest.json";
// Keep in step with TARGETS of scripts/desktop/build-remote-server.sh and the Linux hosts of
// ServerTarget in Core (rust/crates/remote/src/client/bootstrap.rs). `machine` is the ELF
// e_machine, `arch` what server.hello reports and `nodeArch` the matching process.arch.
export const SERVER_TARGETS = Object.freeze({
  "x86_64-unknown-linux-musl": Object.freeze({ machine: 62, arch: "x86_64", nodeArch: "x64" }),
  "aarch64-unknown-linux-musl": Object.freeze({ machine: 183, arch: "aarch64", nodeArch: "arm64" }),
});
// The framing of rust/crates/remote/src/protocol/frame.rs in Core.
export const PREAMBLE = Buffer.from("\nLITHE-REMOTE-PROTOCOL/1\n", "latin1");
export const PREAMBLE_NOISE_LIMIT = 64 * 1024;
export const MAX_FRAME_BYTES = 16 * 1024 * 1024;
export const DEFAULT_TIMEOUT_MS = 20_000;

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..", "..", "..");
const DEFAULT_STAGE_DIR = path.join(ROOT_DIR, ".artifacts", "desktop", "remote-server");
const PIN_FILE = path.join(ROOT_DIR, "scripts", "desktop", "build-desktop-core.sh");
const CLIENT_NAME = "lithe-remote-server-verify";
const HELLO_REQUEST_ID = 1;
const STOP_TIMEOUT_MS = 5_000;
const MAX_CAPTURED_BYTES = 64 * 1024;

const ET_EXEC = 2;
const ET_DYN = 3;
const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_INTERP = 3;
const PN_XNUM = 0xffff;
const DT_NULL = 0n;
const DT_NEEDED = 1n;
const DT_STRTAB = 5n;
const ELF64_HEADER_BYTES = 64;
const ELF64_PROGRAM_HEADER_BYTES = 56;
const ELF64_DYNAMIC_ENTRY_BYTES = 16;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function quoted(bytes, limit = 400) {
  const text = Buffer.from(bytes).subarray(0, limit).toString("utf8");
  return JSON.stringify(bytes.length > limit ? `${text}…` : text);
}

function within(buffer, offset, length, what) {
  if (offset > buffer.length || length > buffer.length - offset) {
    throw new Error(`${what} lies outside the file`);
  }
  return buffer.subarray(offset, offset + length);
}

function unsigned64(buffer, offset, what) {
  const value = buffer.readBigUInt64LE(offset);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`${what} is out of range`);
  }
  return Number(value);
}

// DT_STRTAB is a virtual address; the PT_LOAD segment holding it gives its place in the file.
function libraryName(buffer, segments, stringTable, nameOffset) {
  const unknown = `<name at string offset ${nameOffset}>`;
  if (stringTable === null) {
    return unknown;
  }
  const address = stringTable + nameOffset;
  for (const segment of segments) {
    const start = BigInt(segment.virtualAddress);
    if (segment.type !== PT_LOAD || address < start || address >= start + BigInt(segment.fileSize)) {
      continue;
    }
    const offset = Number(BigInt(segment.offset) + (address - start));
    const end = buffer.indexOf(0, offset);
    return end < 0 ? unknown : buffer.subarray(offset, Math.min(end, offset + 256)).toString("latin1");
  }
  return unknown;
}

/// Reads what decides whether an ELF64 little-endian file runs without a dynamic loader.
/// Throws when the file is not such an ELF file or its tables lie outside it.
export function inspectElf(buffer) {
  if (buffer.length < ELF64_HEADER_BYTES) {
    throw new Error("the file is shorter than an ELF64 header");
  }
  if (buffer.readUInt32BE(0) !== 0x7f454c46) {
    throw new Error("the file is not an ELF file");
  }
  if (buffer[4] !== 2 || buffer[5] !== 1) {
    throw new Error("the file is not a 64-bit little-endian ELF file");
  }
  const type = buffer.readUInt16LE(16);
  const machine = buffer.readUInt16LE(18);
  const entry = unsigned64(buffer, 24, "the entry point");
  const tableOffset = unsigned64(buffer, 32, "the program header table offset");
  const headerSize = buffer.readUInt16LE(54);
  const headerCount = buffer.readUInt16LE(56);
  if (headerCount === PN_XNUM) {
    throw new Error("more program headers than the ELF header can count are not supported");
  }
  if (headerCount > 0 && headerSize < ELF64_PROGRAM_HEADER_BYTES) {
    throw new Error(`program headers of ${headerSize} bytes are too short for ELF64`);
  }
  const segments = [];
  for (let index = 0; index < headerCount; index += 1) {
    const header = within(buffer, tableOffset + index * headerSize, ELF64_PROGRAM_HEADER_BYTES, `program header ${index}`);
    segments.push({
      type: header.readUInt32LE(0),
      offset: unsigned64(header, 8, `the offset of program header ${index}`),
      virtualAddress: unsigned64(header, 16, `the address of program header ${index}`),
      fileSize: unsigned64(header, 32, `the size of program header ${index}`),
    });
  }
  let interpreter = null;
  for (const segment of segments.filter((candidate) => candidate.type === PT_INTERP)) {
    const bytes = within(buffer, segment.offset, segment.fileSize, "the program interpreter");
    const end = bytes.indexOf(0);
    interpreter = bytes.subarray(0, end < 0 ? bytes.length : end).toString("latin1");
  }
  const needed = [];
  for (const segment of segments.filter((candidate) => candidate.type === PT_DYNAMIC)) {
    const table = within(buffer, segment.offset, segment.fileSize, "the dynamic section");
    const names = [];
    let stringTable = null;
    for (let offset = 0; offset + ELF64_DYNAMIC_ENTRY_BYTES <= table.length; offset += ELF64_DYNAMIC_ENTRY_BYTES) {
      const tag = table.readBigInt64LE(offset);
      if (tag === DT_NULL) {
        break;
      }
      const value = table.readBigUInt64LE(offset + 8);
      if (tag === DT_NEEDED) {
        names.push(value);
      } else if (tag === DT_STRTAB) {
        stringTable = value;
      }
    }
    needed.push(...names.map((name) => libraryName(buffer, segments, stringTable, name)));
  }
  return { type, machine, entry, interpreter, needed };
}

/// Lists why an inspected ELF file is not a static executable for `target`.
export function elfProblems(info, target) {
  const expected = SERVER_TARGETS[target];
  const problems = [];
  if (info.type !== ET_EXEC && info.type !== ET_DYN) {
    problems.push(`ELF type ${info.type} is not an executable`);
  }
  if (info.machine !== expected.machine) {
    problems.push(`ELF machine ${info.machine} is not ${expected.arch} (${expected.machine})`);
  }
  if (info.entry === 0) {
    problems.push("the ELF file has no entry point");
  }
  if (info.interpreter !== null) {
    problems.push(`it is dynamically linked: it asks for the program interpreter ${info.interpreter}`);
  }
  if (info.needed.length > 0) {
    problems.push(`it is dynamically linked: it needs ${info.needed.join(", ")}`);
  }
  return problems;
}

/// Lists what is wrong with a parsed manifest; empty when it is well formed.
export function manifestProblems(manifest) {
  if (!isObject(manifest)) {
    return ["the manifest is not a JSON object"];
  }
  const problems = [];
  const expectString = (key, pattern) => {
    if (typeof manifest[key] !== "string" || !pattern.test(manifest[key])) {
      problems.push(`manifest field ${key} is ${JSON.stringify(manifest[key])}`);
    }
  };
  if (manifest.schemaVersion !== 1) {
    problems.push(`manifest schemaVersion ${JSON.stringify(manifest.schemaVersion)} is not 1`);
  }
  expectString("coreRevision", /^[0-9a-f]{40}$/);
  expectString("coreWorktree", /^(clean|dirty)$/);
  expectString("coreSource", /^(pinned|override)$/);
  expectString("serverVersion", /^[0-9A-Za-z][0-9A-Za-z.+-]*$/);
  expectString("rustc", /^rustc \S/);
  expectString("profile", /^release$/);
  if (!Array.isArray(manifest.artifacts)) {
    problems.push("manifest field artifacts is not a list");
    return problems;
  }
  const seen = new Set();
  for (const [index, artifact] of manifest.artifacts.entries()) {
    if (!isObject(artifact) || !Object.hasOwn(SERVER_TARGETS, artifact.target)) {
      problems.push(`manifest artifact ${index} names no known target: ${JSON.stringify(artifact?.target)}`);
      continue;
    }
    const { target } = artifact;
    if (seen.has(target)) {
      problems.push(`manifest lists ${target} more than once`);
    }
    seen.add(target);
    // The path is compared, not resolved, so nothing outside the staging directory is read.
    if (artifact.path !== `${target}/${SERVER_BINARY}`) {
      problems.push(`manifest path of ${target} is ${JSON.stringify(artifact.path)}, not ${target}/${SERVER_BINARY}`);
    }
    if (!Number.isSafeInteger(artifact.size) || artifact.size <= 0) {
      problems.push(`manifest size of ${target} is ${JSON.stringify(artifact.size)}`);
    }
    if (typeof artifact.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(artifact.sha256)) {
      problems.push(`manifest SHA-256 of ${target} is ${JSON.stringify(artifact.sha256)}`);
    }
  }
  for (const target of Object.keys(SERVER_TARGETS)) {
    if (!seen.has(target)) {
      problems.push(`manifest lists no artifact for ${target}`);
    }
  }
  return problems;
}

export function encodeFrame(message) {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(payload.length);
  return Buffer.concat([prefix, payload]);
}

/// Splits a server's standard output into protocol messages the way the Core client does:
/// up to `noiseLimit` bytes before PREAMBLE are discarded, then each frame is a big-endian u32
/// length and that many bytes of UTF-8 JSON.
export function createProtocolReader({ noiseLimit = PREAMBLE_NOISE_LIMIT, maxFrameBytes = MAX_FRAME_BYTES } = {}) {
  let buffered = Buffer.alloc(0);
  let preambleFound = false;
  const decoder = new TextDecoder("utf-8", { fatal: true });
  return {
    get preambleFound() {
      return preambleFound;
    },
    /// What arrived before the preamble, for diagnostics when it never came.
    get noise() {
      return preambleFound ? Buffer.alloc(0) : buffered;
    },
    push(chunk) {
      buffered = Buffer.concat([buffered, chunk]);
      if (!preambleFound) {
        const index = buffered.indexOf(PREAMBLE);
        if (index < 0 ? buffered.length >= noiseLimit + PREAMBLE.length : index > noiseLimit) {
          throw new Error(`no protocol preamble within the first ${noiseLimit} bytes of output: ${quoted(buffered)}`);
        }
        if (index < 0) {
          return [];
        }
        buffered = buffered.subarray(index + PREAMBLE.length);
        preambleFound = true;
      }
      const messages = [];
      while (buffered.length >= 4) {
        const length = buffered.readUInt32BE(0);
        if (length > maxFrameBytes) {
          throw new Error(`a protocol frame of ${length} bytes exceeds the ${maxFrameBytes}-byte limit`);
        }
        if (buffered.length < 4 + length) {
          break;
        }
        const payload = buffered.subarray(4, 4 + length);
        buffered = buffered.subarray(4 + length);
        let text;
        try {
          text = decoder.decode(payload);
        } catch {
          throw new Error("a protocol frame is not UTF-8");
        }
        try {
          messages.push(JSON.parse(text));
        } catch (error) {
          throw new Error(`a protocol frame is not JSON: ${error.message}`);
        }
      }
      return messages;
    },
  };
}

function describeExit({ code, signal }) {
  return signal ? `signal ${signal}` : `exit code ${code}`;
}

function capture(stream) {
  const chunks = [];
  let size = 0;
  stream.on("data", (chunk) => {
    if (size < MAX_CAPTURED_BYTES) {
      chunks.push(chunk.subarray(0, MAX_CAPTURED_BYTES - size));
      size += Math.min(chunk.length, MAX_CAPTURED_BYTES - size);
    }
  });
  return () => Buffer.concat(chunks);
}

/// Starts a process this module owns. On POSIX it leads its own process group, so stop() also
/// ends anything it started. stop() resolves to whether the process is known to have exited.
function startOwnedProcess({ command, args }, env) {
  const child = spawn(command, args, {
    env,
    stdio: ["pipe", "pipe", "pipe"],
    detached: process.platform !== "win32",
    windowsHide: true,
  });
  let exit = null;
  const exited = new Promise((resolve) => {
    child.once("error", (error) => resolve({ code: null, signal: null, error }));
    child.once("close", (code, signal) => resolve({ code, signal, error: null }));
  }).then((result) => {
    exit = result;
    return result;
  });
  // A server that exits early closes its standard input; the write error is not the finding.
  child.stdin.on("error", () => {});
  const stderr = capture(child.stderr);
  const stop = async () => {
    if (child.pid !== undefined && process.platform !== "win32") {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        // The group is already gone.
      }
    }
    if (exit === null) {
      child.kill("SIGKILL");
    }
    let timer;
    const stopped = await Promise.race([
      exited.then(() => true),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(false), STOP_TIMEOUT_MS);
      }),
    ]);
    clearTimeout(timer);
    return stopped;
  };
  return { child, exited, stderr, stop };
}

function withStderr(message, stderr) {
  const text = stderr.toString("utf8").trim();
  return text ? `${message}; standard error: ${quoted(Buffer.from(text))}` : message;
}

/// Runs a command whose standard input is closed and collects its output within the deadline.
async function runToEnd(spawnArgs, { timeoutMs, env }) {
  const owned = startOwnedProcess(spawnArgs, env);
  const stdout = capture(owned.child.stdout);
  owned.child.stdin.end();
  let timer;
  try {
    const result = await Promise.race([
      owned.exited,
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(null), timeoutMs);
      }),
    ]);
    if (result === null) {
      throw new Error(withStderr(`${spawnArgs.command} did not finish within ${timeoutMs} ms`, owned.stderr()));
    }
    if (result.error) {
      throw new Error(`could not start ${spawnArgs.command}: ${result.error.message}`);
    }
    return { ...result, stdout: stdout(), stderr: owned.stderr() };
  } finally {
    clearTimeout(timer);
    if (!(await owned.stop())) {
      throw new Error(`${spawnArgs.command} (pid ${owned.child.pid}) did not stop after SIGKILL`);
    }
  }
}

function helloProblems(result, { protocolVersion, arch, serverVersion }) {
  if (!isObject(result)) {
    return ["server.hello returned no result object"];
  }
  const problems = [];
  if (result.protocolVersion !== protocolVersion) {
    problems.push(`server.hello reports protocol ${JSON.stringify(result.protocolVersion)}, not ${protocolVersion}`);
  }
  if (result.serverVersion !== serverVersion) {
    problems.push(`server.hello reports server ${JSON.stringify(result.serverVersion)}, not ${serverVersion}`);
  }
  if (result.host?.os !== "linux") {
    problems.push(`server.hello reports the operating system ${JSON.stringify(result.host?.os)}, not linux`);
  }
  if (result.host?.arch !== arch) {
    problems.push(`server.hello reports the architecture ${JSON.stringify(result.host?.arch)}, not ${arch}`);
  }
  if (result.session?.persistent !== false) {
    problems.push("server.hello reports a persistent session for --stdio");
  }
  return problems;
}

/// Runs one `--stdio` session: waits for the preamble, sends server.hello, checks the answer,
/// closes standard input and expects the server to exit with 0, all within `timeoutMs`.
export async function stdioHello(spawnArgs, { protocolVersion, arch, serverVersion, timeoutMs = DEFAULT_TIMEOUT_MS, env = process.env }) {
  const owned = startOwnedProcess(spawnArgs, env);
  const reader = createProtocolReader();
  let stage = "waiting for the protocol preamble";
  let hello = null;
  let timer;
  try {
    return await new Promise((resolve, reject) => {
      const fail = (message) => reject(new Error(withStderr(message, owned.stderr())));
      timer = setTimeout(() => fail(`no answer within ${timeoutMs} ms while ${stage}`), timeoutMs);
      owned.child.stdout.on("data", (chunk) => {
        let messages;
        try {
          const before = reader.preambleFound;
          messages = reader.push(chunk);
          if (!before && reader.preambleFound) {
            stage = "waiting for the server.hello response";
            owned.child.stdin.write(encodeFrame({
              type: "request",
              id: HELLO_REQUEST_ID,
              method: "server.hello",
              params: { protocolVersion, clientName: CLIENT_NAME },
            }));
          }
        } catch (error) {
          fail(error.message);
          return;
        }
        for (const message of messages) {
          if (message?.type === "event" || hello !== null) {
            continue;
          }
          if (message?.type !== "response" || message.id !== HELLO_REQUEST_ID) {
            fail(`unexpected message while ${stage}: ${quoted(Buffer.from(JSON.stringify(message)))}`);
            return;
          }
          if (message.error !== undefined) {
            fail(`server.hello failed: ${JSON.stringify(message.error)}`);
            return;
          }
          const problems = helloProblems(message.result, { protocolVersion, arch, serverVersion });
          if (problems.length > 0) {
            fail(problems.join("; "));
            return;
          }
          hello = message.result;
          stage = "waiting for the session to end after standard input closed";
          owned.child.stdin.end();
        }
      });
      owned.exited.then((result) => {
        if (result.error) {
          fail(`could not start ${spawnArgs.command}: ${result.error.message}`);
        } else if (hello === null) {
          const noise = reader.noise.length > 0 ? `; standard output: ${quoted(reader.noise)}` : "";
          fail(`the server exited with ${describeExit(result)} while ${stage}${noise}`);
        } else if (result.code !== 0) {
          fail(`the server exited with ${describeExit(result)} after standard input closed`);
        } else {
          resolve(hello);
        }
      });
    });
  } finally {
    clearTimeout(timer);
    if (!(await owned.stop())) {
      // Reported in place of the session's own result: a process was left behind.
      throw new Error(`${spawnArgs.command} (pid ${owned.child.pid}) did not stop after SIGKILL`);
    }
  }
}

/// How this machine can run an executable of `target`: `{ how, spawnArgs(binary, flags) }`,
/// or `{ skipped }` with the reason it cannot.
export function defaultRunnerFor(target, { platform = process.platform, arch = process.arch } = {}) {
  const expected = SERVER_TARGETS[target];
  if (platform !== "linux") {
    return { skipped: `Linux executables do not run on ${platform}` };
  }
  if (arch !== expected.nodeArch) {
    return { skipped: `it runs only on ${expected.nodeArch} Linux, and this machine is ${arch}` };
  }
  return { how: "native", spawnArgs: (binary, flags) => ({ command: binary, args: flags }) };
}

/// Runs `--identity`, `--version` and a `--stdio` session of one staged executable.
export async function smokeTest({ binary, target, artifact, manifest, runner, timeoutMs = DEFAULT_TIMEOUT_MS, env = process.env }) {
  const identityRun = await runToEnd(runner.spawnArgs(binary, ["--identity"]), { timeoutMs, env });
  if (identityRun.code !== 0) {
    throw new Error(withStderr(`--identity exited with ${describeExit(identityRun)}`, identityRun.stderr));
  }
  let identity;
  try {
    identity = JSON.parse(identityRun.stdout.toString("utf8"));
  } catch {
    throw new Error(`--identity printed no JSON: ${quoted(identityRun.stdout)}`);
  }
  if (!isObject(identity) || !Number.isSafeInteger(identity.protocolVersion) || identity.protocolVersion < 1) {
    throw new Error(`--identity printed no protocol version: ${quoted(identityRun.stdout)}`);
  }
  if (identity.serverVersion !== manifest.serverVersion) {
    throw new Error(`--identity reports server ${JSON.stringify(identity.serverVersion)}, not ${manifest.serverVersion}`);
  }
  // The hash the server computes of itself is what the bootstrapper compares on the host.
  if (identity.sha256 !== artifact.sha256) {
    throw new Error(`--identity reports SHA-256 ${JSON.stringify(identity.sha256)}, not the manifest's ${artifact.sha256}`);
  }
  const versionRun = await runToEnd(runner.spawnArgs(binary, ["--version"]), { timeoutMs, env });
  const version = versionRun.stdout.toString("utf8").trim();
  if (versionRun.code !== 0 || version !== manifest.serverVersion) {
    throw new Error(withStderr(`--version printed ${JSON.stringify(version)} with ${describeExit(versionRun)}, not ${manifest.serverVersion}`, versionRun.stderr));
  }
  await stdioHello(runner.spawnArgs(binary, ["--stdio"]), {
    protocolVersion: identity.protocolVersion,
    arch: SERVER_TARGETS[target].arch,
    serverVersion: manifest.serverVersion,
    timeoutMs,
    env,
  });
  return { protocolVersion: identity.protocolVersion };
}

/// The core revision build-desktop-core.sh pins.
export async function readPinnedCoreRevision(file = PIN_FILE) {
  const match = /^PINNED_CORE_REVISION="([0-9a-f]{40})"$/m.exec(await readFile(file, "utf8"));
  if (match === null) {
    throw new Error(`${file} pins no core revision`);
  }
  return match[1];
}

/// Checks a staging directory. Returns the manifest (when it could be read), one result per
/// artifact and the problems found; never throws for a problem with the artifacts.
/// `smoke` names the only targets to smoke test, each of which must run and pass here; when it
/// is null, every target this machine can run is smoke tested.
export async function verifyArtifacts({
  stageDir = DEFAULT_STAGE_DIR,
  smoke = null,
  pinnedRevision = null,
  runnerFor = defaultRunnerFor,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  env = process.env,
} = {}) {
  const problems = [];
  const results = [];
  const manifestPath = path.join(stageDir, MANIFEST_FILE);
  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    const reason = error.code === "ENOENT" ? "it does not exist; run scripts/desktop/build-remote-server.sh" : error.message;
    return { manifest: null, results, problems: [`cannot read ${manifestPath}: ${reason}`] };
  }
  const invalid = manifestProblems(manifest);
  if (invalid.length > 0) {
    return { manifest: null, results, problems: invalid };
  }
  if (pinnedRevision !== null) {
    if (manifest.coreSource !== "pinned" || manifest.coreWorktree !== "clean" || manifest.coreRevision !== pinnedRevision) {
      problems.push(`the artifacts come from a ${manifest.coreWorktree} ${manifest.coreSource} checkout of ${manifest.coreRevision}, not a clean checkout of the pinned ${pinnedRevision}`);
    }
  }
  for (const artifact of manifest.artifacts) {
    const { target } = artifact;
    const binary = path.join(stageDir, target, SERVER_BINARY);
    const result = { target, size: artifact.size, sha256: artifact.sha256, smoke: "not run" };
    results.push(result);
    const fileProblems = [];
    let contents = null;
    try {
      const status = await lstat(binary);
      if (!status.isFile()) {
        fileProblems.push("it is not a regular file");
      } else if (process.platform !== "win32" && (status.mode & 0o111) === 0) {
        fileProblems.push("it is not executable");
      }
      contents = status.isFile() ? await readFile(binary) : null;
    } catch (error) {
      fileProblems.push(`it cannot be read: ${error.message}`);
    }
    if (contents !== null) {
      if (contents.length !== artifact.size) {
        fileProblems.push(`it has ${contents.length} bytes, not the manifest's ${artifact.size}`);
      }
      const sha256 = createHash("sha256").update(contents).digest("hex");
      if (sha256 !== artifact.sha256) {
        fileProblems.push(`its SHA-256 is ${sha256}, not the manifest's ${artifact.sha256}`);
      }
      try {
        fileProblems.push(...elfProblems(inspectElf(contents), target));
      } catch (error) {
        fileProblems.push(error.message);
      }
    }
    if (fileProblems.length > 0) {
      problems.push(...fileProblems.map((problem) => `${target}: ${problem}`));
      continue;
    }
    if (smoke !== null && !smoke.includes(target)) {
      result.smoke = "not run here";
      continue;
    }
    const runner = runnerFor(target);
    if (runner.skipped !== undefined) {
      result.smoke = `skipped: ${runner.skipped}`;
      if (smoke !== null) {
        problems.push(`${target}: the smoke test is required but cannot run: ${runner.skipped}`);
      }
      continue;
    }
    try {
      const { protocolVersion } = await smokeTest({ binary, target, artifact, manifest, runner, timeoutMs, env });
      result.smoke = `passed (${runner.how}, protocol ${protocolVersion})`;
    } catch (error) {
      result.smoke = `failed (${runner.how})`;
      problems.push(`${target}: smoke test: ${error.message}`);
    }
  }
  return { manifest, results, problems };
}

function bytes(size) {
  const grouped = String(size).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return `${grouped} B (${(size / 1024 / 1024).toFixed(2)} MiB)`;
}

export function formatReport({ manifest, results }) {
  const lines = [
    `Remote server ${manifest.serverVersion} from core ${manifest.coreRevision} (${manifest.coreSource}, ${manifest.coreWorktree}), ${manifest.rustc}`,
  ];
  for (const result of results) {
    lines.push(`  ${result.target.padEnd(28)} ${bytes(result.size).padEnd(26)} sha256 ${result.sha256}  smoke test ${result.smoke}`);
  }
  lines.push("Sizes are reported only; they never fail this check (#2231, D9).");
  return `${lines.join("\n")}\n`;
}

export function formatSummaryMarkdown({ manifest, results }) {
  const lines = [
    "### Remote workspace server",
    "",
    `Server ${manifest.serverVersion}, core \`${manifest.coreRevision}\` (${manifest.coreSource}, ${manifest.coreWorktree}), ${manifest.rustc}. Sizes are reported only (#2231, D9).`,
    "",
    "| Target | Size | SHA-256 | Smoke test |",
    "| --- | --- | --- | --- |",
  ];
  for (const result of results) {
    lines.push(`| \`${result.target}\` | ${bytes(result.size)} | \`${result.sha256}\` | ${result.smoke} |`);
  }
  return `${lines.join("\n")}\n\n`;
}

function usage() {
  return `Usage: node scripts/desktop/verify/verify-remote-server-artifacts.mjs [--stage <dir>] [--smoke <target>|all|none]... [--require-pinned]
Targets: ${Object.keys(SERVER_TARGETS).join(", ")}`;
}

async function main(argv) {
  let stageDir = DEFAULT_STAGE_DIR;
  let smoke = null;
  let requirePinned = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--stage" && index + 1 < argv.length) {
      stageDir = path.resolve(argv[++index]);
    } else if (argument === "--smoke" && index + 1 < argv.length) {
      const target = argv[++index];
      smoke ??= new Set();
      if (target === "all") {
        Object.keys(SERVER_TARGETS).forEach((name) => smoke.add(name));
      } else if (Object.hasOwn(SERVER_TARGETS, target)) {
        smoke.add(target);
      } else if (target !== "none") {
        console.error(`unknown target for --smoke: ${target}`);
        console.error(usage());
        return 2;
      }
    } else if (argument === "--require-pinned") {
      requirePinned = true;
    } else {
      console.error(usage());
      return 2;
    }
  }
  const pinnedRevision = requirePinned ? await readPinnedCoreRevision() : null;
  const outcome = await verifyArtifacts({ stageDir, smoke: smoke === null ? null : [...smoke], pinnedRevision });
  if (outcome.manifest !== null) {
    process.stdout.write(formatReport(outcome));
    if (process.env.GITHUB_STEP_SUMMARY) {
      await appendFile(process.env.GITHUB_STEP_SUMMARY, formatSummaryMarkdown(outcome));
    }
  }
  if (outcome.problems.length > 0) {
    console.error(`Remote server artifacts in ${stageDir} failed verification:`);
    for (const problem of outcome.problems) {
      console.error(`  - ${problem}`);
    }
    return 1;
  }
  console.log("Remote server artifacts verified.");
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
