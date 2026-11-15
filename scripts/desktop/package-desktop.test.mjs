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
            '[[ " $* " == *" --cgo "* ]] || { echo "packaging must retain the native core bridge" >&2; exit 1; }' \\
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

test('Linux packaging retains cgo and embeds its native core helper', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'linux', goarch: 'arm64', rustHost: 'aarch64-unknown-linux-gnu' }, async ({ root, run, coreBuilds }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--no-sign']);
    assert.deepEqual(new Set(await coreBuilds()), new Set(['aarch64-unknown-linux-gnu --release']));
    assert.equal(await readFile(path.join(root, 'embedded-helper.txt'), 'utf8'), 'lithe-mcp for aarch64-unknown-linux-gnu\n');
  });
});

test('make core stages the GNU core on Windows', async () => {
  await withFixture({ goos: 'windows', goarch: 'amd64', rustHost: 'x86_64-pc-windows-msvc' }, async ({ root, run, coreBuilds }) => {
    const output = await run('make', ['-s', '--no-print-directory', '-C', 'desktop', 'core']);
    assert.deepEqual(await coreBuilds(), ['x86_64-pc-windows-gnu --debug']);
    assert.equal(output, path.join(root, 'stage/x86_64-pc-windows-gnu'));
  });
});

test('Windows tool setup preserves the NSIS version switch in Git Bash', { timeout: 20000 }, async () => {
  const action = await readFile(path.join(scripts, '../../.github/actions/setup-desktop-windows-build-tools/action.yml'), 'utf8');
  const body = action.split('      run: |\n')[1].split('\n').map(line => line.slice(8)).join('\n');
  for (const location of ['path', 'x86', 'x64']) {
    const root = await mkdtemp(path.join(os.tmpdir(), 'lithe nsis-check-'));
    try {
      const bin = path.join(root, 'bin');
      const x86 = path.join(root, 'Program Files (x86)/NSIS');
      const x64 = path.join(root, 'Program Files/NSIS');
      await mkdir(bin);
      await mkdir(x86, { recursive: true });
      await mkdir(x64, { recursive: true });
      const nsis = location === 'path' ? path.join(bin, 'makensis') : path.join(location === 'x86' ? x86 : x64, 'makensis.exe');
      // Model the MSYS boundary: the native compiler must receive /VERSION as an option,
      // not a translated Git-installation path. The real native check runs in Windows.
      const commands = {
        gcc: 'exit 0',
        choco: 'echo "unexpected install" >&2; exit 1',
        cygpath: 'printf "%s\\n" "$2"',
      };
      for (const [name, content] of Object.entries(commands)) {
        await writeFile(path.join(bin, name), `#!/usr/bin/env bash\n${content}\n`, { mode: 0o755 });
      }
      await writeFile(nsis, '#!/usr/bin/env bash\nset -eu\n[[ "${MSYS2_ARG_CONV_EXCL:-}" == /VERSION && "$#" == 1 && "$1" == /VERSION ]] || { echo "NSIS version switch was not protected from path conversion" >&2; exit 1; }\nprintf "v3.11\\n"\n', { mode: 0o755 });
      // Force the fallback layouts even if the machine has another NSIS installation.
      const commandLookup = location === 'path' ? '' : 'command() { if [[ "$1" == -v && "$2" == makensis ]]; then return 1; fi; builtin command "$@"; }\n';
      const script = commandLookup + body.replaceAll('/c/Program Files (x86)/NSIS', x86).replaceAll('/c/Program Files/NSIS', x64);
      const result = await runProcess({
        command: 'bash', args: ['-e', '-o', 'pipefail', '-c', script], cwd: root,
        env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, GITHUB_PATH: path.join(root, 'github-path'), MSYS2_ARG_CONV_EXCL: '' },
        timeoutMs: 4000, maxCapturedBytes: 65536,
      });
      assert.equal(result.timedOut, false);
      assert.equal(result.terminationConfirmed, true);
      assert.equal(result.code, 0, `${location}: ${result.stderr}`);
      assert.match(result.stdout, /v3\.11/);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});
