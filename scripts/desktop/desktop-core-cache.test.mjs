import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { runProcess } from '../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));

test('replacing only the staged Core archive invalidates the cgo build cache', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe core-cache-'));
  const env = { ...process.env };
  // This integration test needs the host C compiler, Go and ar, as do desktop builds.
  delete env.GOOS;
  delete env.GOARCH;
  delete env.LITHE_CORE_TARGET;
  delete env.LITHE_DESKTOP_CORE_PROFILE;
  delete env.CGO_CFLAGS;
  delete env.CGO_LDFLAGS;
  async function run(command, args, cwd = root) {
    const result = await runProcess({ command, args, cwd, env, timeoutMs: 120_000, maxCapturedBytes: 1024 * 1024 });
    assert.equal(result.timedOut, false, `${command} timed out: ${result.stderr}`);
    assert.equal(result.terminationConfirmed, true, `${command} left a process tree`);
    assert.equal(result.code, 0, `${command}: ${result.stdout}\n${result.stderr}`);
    return result.stdout.trim();
  }
  try {
    await mkdir(path.join(root, 'scripts/desktop'), { recursive: true });
    await mkdir(path.join(root, 'desktop'));
    await mkdir(path.join(root, 'stage/include'), { recursive: true });
    await mkdir(path.join(root, 'stage/lib'));
    await copyFile(path.join(scripts, 'desktop-go.sh'), path.join(root, 'scripts/desktop/desktop-go.sh'));
    await writeFile(path.join(root, 'scripts/desktop/build-desktop-core.sh'), '#!/usr/bin/env bash\nset -euo pipefail\nROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"\nprintf "%s\\n" "$ROOT_DIR/stage"\n', { mode: 0o755 });
    await writeFile(path.join(root, 'stage/include/lithe_core.h'), 'int fixture_value(void);\n');
    await writeFile(path.join(root, 'stage/native-static-libs.txt'), '');
    await writeFile(path.join(root, 'desktop/go.mod'), 'module lithe.invalid/core-cache-fixture\n\ngo 1.24\n');
    await writeFile(path.join(root, 'desktop/main.go'), 'package main\n/*\n#include "lithe_core.h"\n*/\nimport "C"\nimport "fmt"\nfunc main() { fmt.Println(int(C.fixture_value())) }\n');
    const cc = await run('go', ['env', 'CC']);
    // Match Go's native default compiler without executing shell-expanded text.
    assert.ok(!/\s/.test(cc), `This fixture requires a direct compiler executable, got ${cc}`);
    async function replaceCore(value) {
      await writeFile(path.join(root, 'fixture.c'), `int fixture_value(void) { return ${value}; }\n`);
      await run(cc, ['-c', 'fixture.c', '-o', 'fixture.o']);
      await run('ar', ['rcs', 'stage/lib/liblithe_core.a', 'fixture.o']);
    }
    await replaceCore(1);
    assert.equal(await run('bash', ['scripts/desktop/desktop-go.sh', 'run', '.']), '1');
    await replaceCore(2);
    assert.equal(await run('bash', ['scripts/desktop/desktop-go.sh', 'run', '.']), '2');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
