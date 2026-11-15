import assert from 'node:assert/strict';
import { chmod, copyFile, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { runProcess } from '../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const desktop = path.join(scripts, '../../desktop');

// Go stand-in: reports the simulated host, resolves the Viva module to a fixture directory and
// "builds" a Viva tool that records which lithe-mcp helper was embedded when it packaged.
const fakeGo = `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "-C" ]]; then shift 2; fi
case "$1" in
    env)
        case "$2" in
            GOOS) printf '%s\\n' "\${GOOS:-$FIXTURE_GOOS}" ;;
            GOHOSTOS) printf '%s\\n' "$FIXTURE_GOOS" ;;
            GOARCH) printf '%s\\n' "\${GOARCH:-$FIXTURE_GOARCH}" ;;
            GOEXE) if [[ "$FIXTURE_GOOS" == windows ]]; then printf '.exe\\n'; else printf '\\n'; fi ;;
            *) printf 'unexpected go env %s\\n' "$2" >&2; exit 1 ;;
        esac
        ;;
    mod) ;;
    list)
        case "$4" in
            *.Dir*) printf '%s\\n' "$FIXTURE_ROOT/viva-src" ;;
            *) printf 'v0.0.0-fixture\\n' ;;
        esac
        ;;
    build)
        printf '%s\\n' '#!/usr/bin/env bash' 'set -euo pipefail' \\
            'cp internal/idehelp/lithe-mcp.bin "$FIXTURE_ROOT/embedded-helper.txt"' > "$3"
        chmod +x "$3"
        ;;
    *) printf 'unexpected go command: %s\\n' "$*" >&2; exit 1 ;;
esac
`;

const fakeRustc = `#!/usr/bin/env bash
printf 'rustc 0.0.0-fixture\\nhost: %s\\n' "$FIXTURE_RUST_HOST"
`;

// build-desktop-core.sh stand-in with the real script's target contract: LITHE_CORE_TARGET, else the
// rustc host, and an MSVC target is refused. Each staged helper names the target it was built for.
const fakeCoreBuild = `#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd -P)"
host="$(rustc -vV | sed -n 's/^host: //p')"
target="\${LITHE_CORE_TARGET:-$host}"
printf '%s %s\\n' "$target" "$1" >> "$ROOT_DIR/core-builds.txt"
if [[ "$target" == *-windows-msvc ]]; then
    printf 'cgo cannot link the MSVC .lib archive for %s\\n' "$target" >&2
    exit 2
fi
stage="$ROOT_DIR/stage/$target"
helper="lithe-mcp"
if [[ "$target" == *windows* ]]; then helper="lithe-mcp.exe"; fi
mkdir -p "$stage/include" "$stage/lib" "$stage/bin"
: > "$stage/include/lithe_core.h"
: > "$stage/lib/liblithe_core.a"
: > "$stage/native-static-libs.txt"
printf 'lithe-mcp for %s\\n' "$target" > "$stage/bin/$helper"
chmod +x "$stage/bin/$helper"
printf '%s\\n' "$stage"
`;

async function withFixture(host, body) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe package-desktop-'));
  try {
    const bin = path.join(root, 'fake-bin');
    await mkdir(path.join(root, 'scripts/desktop'), { recursive: true });
    await mkdir(path.join(root, 'desktop'));
    await mkdir(path.join(root, 'viva-src'));
    await mkdir(bin);
    for (const name of ['package-desktop.sh', 'desktop-go.sh']) {
      await copyFile(path.join(scripts, name), path.join(root, 'scripts/desktop', name));
    }
    await copyFile(path.join(desktop, 'Makefile'), path.join(root, 'desktop/Makefile'));
    await writeFile(path.join(root, 'desktop/viva.toml'), '[app]\nversion = "0.0.1"\n');
    await writeFile(path.join(root, 'scripts/desktop/build-desktop-core.sh'), fakeCoreBuild);
    await writeFile(path.join(bin, 'go'), fakeGo);
    await writeFile(path.join(bin, 'rustc'), fakeRustc);
    for (const file of ['scripts/desktop/build-desktop-core.sh', 'fake-bin/go', 'fake-bin/rustc']) {
      await chmod(path.join(root, file), 0o755);
    }
    const env = {
      ...process.env,
      PATH: `${bin}${path.delimiter}${process.env.PATH}`,
      FIXTURE_ROOT: root,
      FIXTURE_GOOS: host.goos,
      FIXTURE_GOARCH: host.goarch,
      FIXTURE_RUST_HOST: host.rustHost,
    };
    for (const name of ['GOOS', 'GOARCH', 'LITHE_CORE_TARGET', 'LITHE_CORE_RUST_DIR', 'LITHE_DESKTOP_CORE_PROFILE',
      'CGO_CFLAGS', 'CGO_LDFLAGS', 'MACOSX_DEPLOYMENT_TARGET', 'MAKEFLAGS', 'MFLAGS', 'MAKELEVEL']) {
      delete env[name];
    }
    async function run(command, args) {
      const result = await runProcess({ command, args, cwd: root, env, timeoutMs: 60_000, maxCapturedBytes: 1024 * 1024 });
      assert.equal(result.timedOut, false, `${command} timed out: ${result.stderr}`);
      assert.equal(result.terminationConfirmed, true, `${command} left a process tree`);
      assert.equal(result.code, 0, `${command} ${args.join(' ')}: ${result.stdout}\n${result.stderr}`);
      return result.stdout.trim();
    }
    const coreBuilds = async () => (await readFile(path.join(root, 'core-builds.txt'), 'utf8')).trim().split('\n');
    await body({ root: await realpath(root), run, coreBuilds });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test('Windows packaging stages and embeds the GNU core when rustc defaults to MSVC', async () => {
  await withFixture({ goos: 'windows', goarch: 'amd64', rustHost: 'x86_64-pc-windows-msvc' }, async ({ root, run, coreBuilds }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--no-sign']);
    assert.deepEqual(new Set(await coreBuilds()), new Set(['x86_64-pc-windows-gnu --release']));
    assert.equal(await readFile(path.join(root, 'embedded-helper.txt'), 'utf8'), 'lithe-mcp for x86_64-pc-windows-gnu\n');
  });
});

test('an amd64 macOS package on an arm64 host embeds the amd64 helper', async () => {
  await withFixture({ goos: 'darwin', goarch: 'arm64', rustHost: 'aarch64-apple-darwin' }, async ({ root, run, coreBuilds }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--arch', 'amd64', '--no-sign']);
    assert.deepEqual(new Set(await coreBuilds()), new Set(['x86_64-apple-darwin --release']));
    assert.equal(await readFile(path.join(root, 'embedded-helper.txt'), 'utf8'), 'lithe-mcp for x86_64-apple-darwin\n');
  });
});

test('make core stages the GNU core on Windows', async () => {
  await withFixture({ goos: 'windows', goarch: 'amd64', rustHost: 'x86_64-pc-windows-msvc' }, async ({ root, run, coreBuilds }) => {
    const output = await run('make', ['-s', '--no-print-directory', '-C', 'desktop', 'core']);
    assert.deepEqual(await coreBuilds(), ['x86_64-pc-windows-gnu --debug']);
    assert.equal(output, path.join(root, 'stage/x86_64-pc-windows-gnu'));
  });
});
