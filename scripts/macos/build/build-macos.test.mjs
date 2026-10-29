import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const arm = "arm64-apple-macosx";
const intel = "x86_64-apple-macosx";
const compiler = "fixture Swift version 6.4 (compiler-build-A)";
const identity = (version = compiler) => `lithe-swift-build-cache-v2\n${version}\n`;

async function withFixture(body) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "lithe-swift-cache-")));
  try {
    await fs.mkdir(path.join(root, "scripts/macos/build"), { recursive: true });
    await fs.mkdir(path.join(root, "bin"));
    await fs.copyFile(path.join(scriptDirectory, "build-macos.sh"), path.join(root, "scripts/macos/build/build-macos.sh"));
    // Stub the helpers at the paths build-macos.sh invokes them from.
    for (const stub of ["macos/verify/verify-macos-app-build-safety.sh", "editor/build-editor.sh", "rust-core/build-rust-core.sh"]) {
      const target = path.join(root, "scripts", stub);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.writeFile(target, "#!/bin/zsh\nprint -- /fixture/liblithe_core.a\n", { mode: 0o755 });
    }
    // Replace only external build tools; execute the real argument/stamp logic.
    await fs.writeFile(path.join(root, "bin/swift"), `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const root = process.cwd();
const value = name => args[args.indexOf(name) + 1];
const scratch = args.includes('--scratch-path') ? value('--scratch-path') : path.join(root, '.build');
fs.appendFileSync(path.join(root, 'calls.jsonl'), JSON.stringify({ args, scratch }) + '\\n');
if (args.includes('--version')) {
  console.log(process.env.FIXTURE_COMPILER);
} else if (args.includes('--show-bin-path')) {
  console.log(process.env.FIXTURE_LAYOUT === 'native'
    ? path.join(scratch, args.includes('--triple') ? value('--triple') : '${arm}', 'debug')
    : path.join(scratch, 'out/Products/Debug'));
} else if (args[0] === 'package' && args.includes('clean')) {
  if (process.env.FIXTURE_CLEAN_FAIL === '1') process.exit(9);
  for (const name of ['out', 'stale-products', '.lithe-swift-toolchain']) {
    fs.rmSync(path.join(scratch, name), { force: true, recursive: true });
  }
} else if (args[0] === 'build') {
  if (process.env.FIXTURE_BUILD_FAIL === '1') process.exit(8);
} else {
  throw new Error('Unexpected Swift invocation: ' + args.join(' '));
}
`, { mode: 0o755 });
    const fixture = {
      root,
      cache: triple => path.join(root, ".build", triple ?? ""),
      async seed(triple, version) {
        const cache = this.cache(triple);
        await fs.mkdir(path.join(cache, "out/Products/Debug/SwiftTerm_SwiftTerm.bundle"), { recursive: true });
        await fs.writeFile(path.join(cache, "out/Products/Debug/SwiftTerm_SwiftTerm.bundle/Shaders.metal"), "stale");
        await fs.mkdir(path.join(cache, "checkouts/SwiftTerm"), { recursive: true });
        await fs.writeFile(path.join(cache, "checkouts/SwiftTerm/Package.swift"), "checkout");
        if (version !== undefined) await fs.writeFile(path.join(cache, ".lithe-swift-toolchain"), version);
      },
      run(triple = arm, environment = {}) {
        const args = [path.join(root, "scripts/macos/build/build-macos.sh")];
        if (triple) args.push("--triple", triple);
        return spawnSync("/bin/zsh", args, {
          cwd: root,
          encoding: "utf8",
          timeout: 10000,
          env: {
            ...process.env,
            PATH: `${path.join(root, "bin")}:${process.env.PATH}`,
            SWIFT_EXEC: "",
            FIXTURE_COMPILER: compiler,
            FIXTURE_LAYOUT: "swiftbuild",
            ...environment,
          },
        });
      },
      async calls() {
        return (await fs.readFile(path.join(root, "calls.jsonl"), "utf8")).trim().split("\n").map(JSON.parse);
      },
    };
    await body(fixture);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

function succeeded(result) {
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
}

test("a matching global stamp cannot hide an unknown architecture cache", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm);
    await fs.writeFile(path.join(fixture.cache(), ".lithe-swift-toolchain"), `${compiler}\n`);
    succeeded(fixture.run());
    const calls = await fixture.calls();
    assert.deepEqual(calls.find(call => call.args[0] === "package").args, ["package", "--scratch-path", fixture.cache(arm), "clean"]);
    assert.equal(calls.find(call => call.args[0] === "build" && !call.args.includes("--show-bin-path")).scratch, fixture.cache(arm));
    await assert.rejects(fs.access(path.join(fixture.cache(arm), "out/Products/Debug/SwiftTerm_SwiftTerm.bundle/Shaders.metal")));
    assert.equal(await fs.readFile(path.join(fixture.cache(arm), "checkouts/SwiftTerm/Package.swift"), "utf8"), "checkout");
    assert.equal(await fs.readFile(path.join(fixture.cache(arm), ".lithe-swift-toolchain"), "utf8"), identity());
    assert.equal(await fs.readFile(path.join(fixture.cache(), ".lithe-swift-toolchain"), "utf8"), `${compiler}\n`);
  });
});

test("a validated compiler cache resumes without cleaning", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm, identity());
    succeeded(fixture.run());
    assert.ok(!(await fixture.calls()).some(call => call.args[0] === "package"));
    await fs.access(path.join(fixture.cache(arm), "out/Products/Debug/SwiftTerm_SwiftTerm.bundle/Shaders.metal"));
  });
});

test("cold builds create their architecture stamp without cleaning", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    succeeded(fixture.run());
    assert.ok(!(await fixture.calls()).some(call => call.args[0] === "package"));
    assert.equal(await fs.readFile(path.join(fixture.cache(arm), ".lithe-swift-toolchain"), "utf8"), identity());
  });
});

test("old policy stamps are migrated even when the compiler matches", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm, `${compiler}\n`);
    succeeded(fixture.run());
    assert.equal((await fixture.calls()).filter(call => call.args[0] === "package").length, 1);
    assert.equal(await fs.readFile(path.join(fixture.cache(arm), ".lithe-swift-toolchain"), "utf8"), identity());
  });
});

test("compiler changes invalidate each architecture independently", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    const old = identity("fixture Swift version 6.3.3 (compiler-build-B)");
    await fixture.seed(arm, old);
    await fixture.seed(intel, old);
    succeeded(fixture.run());
    assert.equal(await fs.readFile(path.join(fixture.cache(intel), ".lithe-swift-toolchain"), "utf8"), old);
    await fs.access(path.join(fixture.cache(intel), "out/Products/Debug/SwiftTerm_SwiftTerm.bundle/Shaders.metal"));
    succeeded(fixture.run(intel));
    succeeded(fixture.run());
    const cleaned = (await fixture.calls()).filter(call => call.args[0] === "package");
    assert.deepEqual(cleaned.map(call => call.scratch), [fixture.cache(arm), fixture.cache(intel)]);
  });
});

test("failed cleanup does not record success or start a build", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm, "old compiler\n");
    const result = fixture.run(arm, { FIXTURE_CLEAN_FAIL: "1" });
    assert.ifError(result.error);
    assert.equal(result.status, 9, result.stdout + result.stderr);
    assert.equal(await fs.readFile(path.join(fixture.cache(arm), ".lithe-swift-toolchain"), "utf8"), "old compiler\n");
    assert.ok(!(await fixture.calls()).some(call => call.args[0] === "build" && !call.args.includes("--show-bin-path")));
  });
});

test("an interrupted compilation keeps the cleaned compiler identity for resuming", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm);
    const result = fixture.run(arm, { FIXTURE_BUILD_FAIL: "1" });
    assert.ifError(result.error);
    assert.equal(result.status, 8, result.stdout + result.stderr);
    succeeded(fixture.run());
    assert.equal((await fixture.calls()).filter(call => call.args[0] === "package").length, 1);
  });
});

test("legacy SwiftPM keeps its default scratch path", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(undefined, `${compiler}\n`);
    succeeded(fixture.run(arm, { FIXTURE_LAYOUT: "native" }));
    const calls = await fixture.calls();
    assert.deepEqual(calls.find(call => call.args[0] === "package").args, ["package", "clean"]);
    assert.ok(!calls.some(call => call.args.includes("--scratch-path")));
    assert.equal(await fs.readFile(path.join(fixture.cache(), ".lithe-swift-toolchain"), "utf8"), identity());
  });
});

test("a default build uses a separate root identity from architecture scratch caches", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm, identity());
    await fixture.seed(undefined, "old compiler\n");
    succeeded(fixture.run(null));
    assert.deepEqual((await fixture.calls()).find(call => call.args[0] === "package").args, ["package", "clean"]);
    assert.equal(await fs.readFile(path.join(fixture.cache(), ".lithe-swift-toolchain"), "utf8"), identity());
  });
});

test("SWIFT_EXEC compiler identity participates in cache invalidation", { timeout: 15000 }, async () => {
  await withFixture(async fixture => {
    await fixture.seed(arm, identity());
    const executable = path.join(fixture.root, "bin/alternate-swift");
    await fs.writeFile(executable, "#!/bin/zsh\nprint -- 'alternate compiler build'\n", { mode: 0o755 });
    succeeded(fixture.run(arm, { SWIFT_EXEC: executable }));
    assert.equal((await fixture.calls()).filter(call => call.args[0] === "package").length, 1);
    assert.equal(await fs.readFile(path.join(fixture.cache(arm), ".lithe-swift-toolchain"), "utf8"), `${identity().trimEnd()}\nalternate compiler build\n`);
  });
});
