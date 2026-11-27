import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { chmod, copyFile, mkdir, mkdtemp, readdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { runProcess } from '../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const desktop = path.join(scripts, '../../desktop');

// Go stand-in: reports the simulated host, resolves the Viva module to a fixture directory and
// "builds" a Viva tool that records which lithe-mcp helper and build information it packaged.
const fakeGo = `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "-C" ]]; then shift 2; fi
case "$1" in
    env)
        case "$2" in
            GOOS) printf '%s\\n' "\${GOOS:-$FIXTURE_GOOS}" ;;
            GOHOSTOS) printf '%s\\n' "$FIXTURE_GOOS" ;;
            GOHOSTARCH) printf '%s\\n' "$FIXTURE_GOARCH" ;;
            GOARCH) printf '%s\\n' "\${GOARCH:-$FIXTURE_GOARCH}" ;;
            GOEXE) if [[ "$FIXTURE_GOOS" == windows ]]; then printf '.exe\\n'; else printf '\\n'; fi ;;
            *) printf 'unexpected go env %s\\n' "$2" >&2; exit 1 ;;
        esac
        ;;
    mod) ;;
    run)
        [[ "$2" == ./cmd/file-associations-manifest && "$3" == --check ]]
        ;;
    list)
        case "$4" in
            *.Dir*) printf '%s\\n' "$FIXTURE_ROOT/viva-src" ;;
            *) printf 'v0.0.0-fixture\\n' ;;
        esac
        ;;
    build)
        printf '%s\\n' '#!/usr/bin/env bash' 'set -euo pipefail' \\
            '[[ " $* " == *" --cgo "* ]] || { echo "packaging must retain the native core bridge" >&2; exit 1; }' \\
            'printf "%s\\n" "$@" > "$FIXTURE_ROOT/viva-args.txt"' \\
            'cp internal/idehelp/lithe-mcp.bin "$FIXTURE_ROOT/embedded-helper.txt"' \\
            'cp internal/buildinfo/package_info.go "$FIXTURE_ROOT/package-info.go"' \\
            'rm -rf "$FIXTURE_ROOT/embedded-remote-server"' \\
            'cp -R internal/remoteserver "$FIXTURE_ROOT/embedded-remote-server"' > "$3"
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

// build-remote-server.sh stand-in: records that it ran and prints the stage withFixture wrote.
const fakeServerBuild = `#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd -P)"
printf 'built\\n' >> "$ROOT_DIR/remote-server-builds.txt"
printf '%s\\n' "$ROOT_DIR/remote-stage/built"
`;

// verify-remote-server-artifacts.mjs stand-in: records its arguments, and fails when asked to.
const fakeServerVerify = `import { appendFileSync } from 'node:fs';
appendFileSync(process.env.FIXTURE_ROOT + '/remote-server-verify.txt', JSON.stringify(process.argv.slice(2)) + '\\n');
if (process.env.FIXTURE_VERIFY_FAIL) {
  console.error('the remote server check failed');
  process.exit(1);
}
`;

const serverTargets = ['x86_64-unknown-linux-musl', 'aarch64-unknown-linux-musl'];

// writeServerStage writes what build-remote-server.sh stages, with one build per target whose bytes
// name the stage. A changed target gets other bytes than its manifest describes.
async function writeServerStage(dir, name, changed) {
  const artifacts = [];
  for (const target of serverTargets) {
    const build = `${name} server for ${target}\n`;
    await mkdir(path.join(dir, target), { recursive: true });
    await writeFile(path.join(dir, target, 'lithe-remote-server'), target === changed ? `${build}changed\n` : build, { mode: 0o755 });
    artifacts.push({ target, path: `${target}/lithe-remote-server`, size: build.length, sha256: createHash('sha256').update(build).digest('hex') });
  }
  await writeFile(path.join(dir, 'remote-server-manifest.json'), `${JSON.stringify({
    schemaVersion: 1, coreRevision: '0123456789abcdef0123456789abcdef01234567', coreWorktree: 'clean', coreSource: 'pinned',
    serverVersion: '0.1.0', rustc: 'rustc 0.0.0-fixture', profile: 'release', artifacts,
  }, null, 2)}\n`);
}

async function withFixture(host, body) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe package-desktop-'));
  try {
    const bin = path.join(root, 'fake-bin');
    await mkdir(path.join(root, 'scripts/desktop'), { recursive: true });
    await mkdir(path.join(root, 'scripts/ci/common'), { recursive: true });
    await copyFile(path.join(scripts, '../ci/common/desktop-packages.mjs'), path.join(root, 'scripts/ci/common/desktop-packages.mjs'));
    await mkdir(path.join(root, 'desktop/internal/buildinfo'), { recursive: true });
    // The tracked sources of the package the server builds are embedded into, which packaging keeps.
    await mkdir(path.join(root, 'desktop/internal/remoteserver'), { recursive: true });
    await writeFile(path.join(root, 'desktop/internal/remoteserver/remoteserver.go'), 'package remoteserver\n');
    await mkdir(path.join(root, 'scripts/desktop/verify'), { recursive: true });
    await mkdir(path.join(root, 'viva-src'));
    await mkdir(bin);
    for (const name of ['package-desktop.sh', 'build-viva-tool.sh', 'desktop-go.sh', 'generate-file-associations.sh']) {
      await copyFile(path.join(scripts, name), path.join(root, 'scripts/desktop', name));
    }
    await copyFile(path.join(desktop, 'Makefile'), path.join(root, 'desktop/Makefile'));
    await writeFile(path.join(root, 'desktop/viva.toml'), '[app]\nversion = "0.0.1"\n');
    await writeFile(path.join(root, 'scripts/desktop/build-desktop-core.sh'), fakeCoreBuild);
    await writeFile(path.join(root, 'scripts/desktop/build-remote-server.sh'), fakeServerBuild);
    await writeFile(path.join(root, 'scripts/desktop/verify/verify-remote-server-artifacts.mjs'), fakeServerVerify);
    await writeServerStage(path.join(root, 'remote-stage/built'), 'built');
    await writeFile(path.join(bin, 'go'), fakeGo);
    await writeFile(path.join(bin, 'rustc'), fakeRustc);
    for (const file of ['scripts/desktop/build-desktop-core.sh', 'scripts/desktop/build-remote-server.sh', 'fake-bin/go', 'fake-bin/rustc']) {
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
      'CGO_CFLAGS', 'CGO_LDFLAGS', 'MACOSX_DEPLOYMENT_TARGET', 'MAKEFLAGS', 'MFLAGS', 'MAKELEVEL',
      'LITHE_BUILD_TIME', 'LITHE_BUILD_COMMIT', 'LITHE_UPDATE_PUBLIC_KEYS', 'LITHE_REMOTE_SERVER_STAGE']) {
      delete env[name];
    }
    async function exec(command, args, extra) {
      const result = await runProcess({ command, args, cwd: root, env: { ...env, ...extra }, timeoutMs: 60_000, maxCapturedBytes: 1024 * 1024 });
      assert.equal(result.timedOut, false, `${command} timed out: ${result.stderr}`);
      assert.equal(result.terminationConfirmed, true, `${command} left a process tree`);
      return result;
    }
    async function run(command, args, extra = {}) {
      const result = await exec(command, args, extra);
      assert.equal(result.code, 0, `${command} ${args.join(' ')}: ${result.stdout}\n${result.stderr}`);
      return result.stdout.trim();
    }
    // refused runs a command that must stop with a usage error and returns what it said.
    async function refused(command, args, extra = {}) {
      const result = await exec(command, args, extra);
      assert.equal(result.code, 2, `${command} ${args.join(' ')} should be refused: ${result.stdout}\n${result.stderr}`);
      return result.stderr;
    }
    // failed runs a command that must fail after the usage checks and returns what it said.
    async function failed(command, args, extra = {}) {
      const result = await exec(command, args, extra);
      assert.equal(result.code, 1, `${command} ${args.join(' ')} should fail: ${result.stdout}\n${result.stderr}`);
      return result.stderr;
    }
    const coreBuilds = async () => (await readFile(path.join(root, 'core-builds.txt'), 'utf8')).trim().split('\n');
    await body({ root: await realpath(root), run, refused, failed, coreBuilds });
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
    // The catalog checker executes on the host; the packaged helper still comes
    // from the target stage, independently of that first host-tool build.
    assert.deepEqual(new Set(await coreBuilds()), new Set(['aarch64-apple-darwin --release', 'x86_64-apple-darwin --release']));
    assert.equal(await readFile(path.join(root, 'embedded-helper.txt'), 'utf8'), 'lithe-mcp for x86_64-apple-darwin\n');
  });
});

test('skipping the file associations check avoids a second host-arch release Core build when cross-packaging', async () => {
  await withFixture({ goos: 'darwin', goarch: 'arm64', rustHost: 'aarch64-apple-darwin' }, async ({ root, run, coreBuilds }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--arch', 'amd64', '--no-sign', '--skip-file-associations-check']);
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

test('macOS ad hoc packaging uses Viva signing rather than skipping the resource seal', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'darwin', goarch: 'arm64', rustHost: 'aarch64-apple-darwin' }, async ({ root, run }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--ad-hoc-sign']);
    const args = (await readFile(path.join(root, 'viva-args.txt'), 'utf8')).trim().split('\n');
    assert.equal(args[args.indexOf('--sign-identity') + 1], '-');
    assert.equal(args.includes('--no-sign'), false);
  });
});

const fixtureKey = 'MCowBQYDK2VwAyEAfixturefixturefixturefixturefixt=';

test('an AutoBuild package records its channel, time, commit and feed keys, then removes the file', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'linux', goarch: 'amd64', rustHost: 'x86_64-unknown-linux-gnu' }, async ({ root, run }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--autobuild', '--no-sign'], {
      LITHE_BUILD_TIME: '2026-11-16T10:00:00Z',
      LITHE_BUILD_COMMIT: '0123456789abcdef0123456789abcdef01234567',
      LITHE_UPDATE_PUBLIC_KEYS: ` ${fixtureKey},\n${fixtureKey} `,
    });
    const info = await readFile(path.join(root, 'package-info.go'), 'utf8');
    assert.match(info, /^\/\/ Code generated .* DO NOT EDIT\.\n\n\/\/go:build lithe_package_info\n\npackage buildinfo\n/);
    assert.match(info, /\tChannel = "autobuild"\n/);
    assert.match(info, /\tBuildTime = "2026-11-16T10:00:00Z"\n/);
    assert.match(info, /\tCommit = "0123456789abcdef0123456789abcdef01234567"\n/);
    assert.ok(info.includes(`\tUpdatePublicKeys = "${fixtureKey},${fixtureKey}"\n`), info);
    const args = (await readFile(path.join(root, 'viva-args.txt'), 'utf8')).trim().split('\n');
    const tags = args[args.indexOf('-tags') + 1].split(',');
    assert.ok(tags.includes('lithe_package_info'), tags.join(','));
    assert.equal(tags.includes('lithe_stable'), false);
    await assert.rejects(readFile(path.join(root, 'desktop/internal/buildinfo/package_info.go')), { code: 'ENOENT' });
  });
});

test('a stable package updates from the stable channel; a local one has no channel', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'linux', goarch: 'amd64', rustHost: 'x86_64-unknown-linux-gnu' }, async ({ root, run }) => {
    await run('bash', ['scripts/desktop/package-desktop.sh', '--stable', '--no-sign'], { LITHE_UPDATE_PUBLIC_KEYS: fixtureKey });
    assert.match(await readFile(path.join(root, 'package-info.go'), 'utf8'), /\tChannel = "stable"\n/);
    const tags = (await readFile(path.join(root, 'viva-args.txt'), 'utf8')).trim().split('\n');
    assert.ok(tags[tags.indexOf('-tags') + 1].split(',').includes('lithe_stable'));
    await run('bash', ['scripts/desktop/package-desktop.sh', '--no-sign'], { LITHE_BUILD_COMMIT: 'abcdef1' });
    const local = await readFile(path.join(root, 'package-info.go'), 'utf8');
    assert.match(local, /\tChannel = ""\n/);
    assert.match(local, /\tBuildTime = "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"\n/);
    assert.match(local, /\tCommit = "abcdef1"\n/);
    assert.match(local, /\tUpdatePublicKeys = ""\n/);
  });
});

test('packaging refuses two channels and build information a Go string would need escaped', { timeout: 30000 }, async () => {
  await withFixture({ goos: 'linux', goarch: 'amd64', rustHost: 'x86_64-unknown-linux-gnu' }, async ({ refused }) => {
    assert.match(await refused('bash', ['scripts/desktop/package-desktop.sh', '--stable', '--autobuild']), /different channels/);
    assert.match(await refused('bash', ['scripts/desktop/package-desktop.sh'], { LITHE_UPDATE_PUBLIC_KEYS: 'key"+os.Exit(1)+"' }), /LITHE_UPDATE_PUBLIC_KEYS/);
    assert.match(await refused('bash', ['scripts/desktop/package-desktop.sh'], { LITHE_BUILD_COMMIT: 'main' }), /LITHE_BUILD_COMMIT/);
    assert.match(await refused('bash', ['scripts/desktop/package-desktop.sh'], { LITHE_BUILD_TIME: 'yesterday' }), /LITHE_BUILD_TIME/);
  });
});

// generatedFiles lists what packaging left in the directories it generates build input in.
async function generatedFiles(root) {
  const left = [];
  for (const [dir, tracked] of [['desktop/internal/idehelp', []], ['desktop/internal/buildinfo', []], ['desktop/internal/remoteserver', ['remoteserver.go']]]) {
    const entries = await readdir(path.join(root, dir)).catch(error => (error.code === 'ENOENT' ? [] : Promise.reject(error)));
    left.push(...entries.filter(name => !tracked.includes(name)).map(name => `${dir}/${name}`));
  }
  return left;
}

async function assertEmbedsStage(root, stage) {
  const embedded = path.join(root, 'embedded-remote-server');
  assert.deepEqual((await readdir(embedded)).sort(), [...serverTargets.map(target => `${target}.bin`), 'remote-server-manifest.json', 'remoteserver.go'].sort());
  assert.equal(await readFile(path.join(embedded, 'remote-server-manifest.json'), 'utf8'), await readFile(path.join(stage, 'remote-server-manifest.json'), 'utf8'));
  for (const target of serverTargets) {
    assert.equal(await readFile(path.join(embedded, `${target}.bin`), 'utf8'), await readFile(path.join(stage, target, 'lithe-remote-server'), 'utf8'));
  }
  const args = (await readFile(path.join(root, 'viva-args.txt'), 'utf8')).trim().split('\n');
  assert.ok(args[args.indexOf('-tags') + 1].split(',').includes('lithe_bundled_remote_server'));
}

const verifyRuns = async root => (await readFile(path.join(root, 'remote-server-verify.txt'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));

test('a local package builds the remote server and embeds every build of its manifest', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'linux', goarch: 'amd64', rustHost: 'x86_64-unknown-linux-gnu' }, async ({ root, run }) => {
    // A build an interrupted run left is not embedded.
    await writeFile(path.join(root, 'desktop/internal/remoteserver/riscv64gc-unknown-linux-musl.bin'), 'stale\n');
    await run('bash', ['scripts/desktop/package-desktop.sh', '--no-sign']);
    const stage = path.join(root, 'remote-stage/built');
    assert.equal(await readFile(path.join(root, 'remote-server-builds.txt'), 'utf8'), 'built\n');
    assert.deepEqual(await verifyRuns(root), [['--stage', stage]]);
    await assertEmbedsStage(root, stage);
    assert.deepEqual(await generatedFiles(root), []);
  });
});

test('a release package embeds the stage CI built, checked against the pinned core', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'darwin', goarch: 'arm64', rustHost: 'aarch64-apple-darwin' }, async ({ root, run }) => {
    const stage = path.join(root, 'remote-stage/downloaded by CI');
    await writeServerStage(stage, 'CI');
    await run('bash', ['scripts/desktop/package-desktop.sh', '--stable', '--no-sign'], { LITHE_REMOTE_SERVER_STAGE: stage });
    await assert.rejects(readFile(path.join(root, 'remote-server-builds.txt')), { code: 'ENOENT' });
    assert.deepEqual(await verifyRuns(root), [['--stage', stage, '--require-pinned']]);
    await assertEmbedsStage(root, stage);
    assert.deepEqual(await generatedFiles(root), []);
  });
});

test('packaging stops before building the client when a remote server build fails its check', { timeout: 90000 }, async () => {
  await withFixture({ goos: 'linux', goarch: 'amd64', rustHost: 'x86_64-unknown-linux-gnu' }, async ({ root, failed }) => {
    assert.match(await failed('bash', ['scripts/desktop/package-desktop.sh', '--no-sign'], { FIXTURE_VERIFY_FAIL: '1' }), /the remote server check failed/);
    await assert.rejects(readFile(path.join(root, 'viva-args.txt')), { code: 'ENOENT' });
    assert.deepEqual(await generatedFiles(root), []);

    // A build that changes after the check is refused when it is copied, and nothing stays behind.
    const stage = path.join(root, 'remote-stage/changed');
    await writeServerStage(stage, 'changed', 'aarch64-unknown-linux-musl');
    assert.match(await failed('bash', ['scripts/desktop/package-desktop.sh', '--no-sign'], { LITHE_REMOTE_SERVER_STAGE: stage }),
      /The staged aarch64-unknown-linux-musl server changed after it was checked\./);
    await assert.rejects(readFile(path.join(root, 'viva-args.txt')), { code: 'ENOENT' });
    assert.deepEqual(await generatedFiles(root), []);
  });
});

test('make core stages the GNU core on Windows', async () => {
  await withFixture({ goos: 'windows', goarch: 'amd64', rustHost: 'x86_64-pc-windows-msvc' }, async ({ root, run, coreBuilds }) => {
    const output = await run('make', ['-s', '--no-print-directory', '-C', 'desktop', 'core']);
    assert.deepEqual(await coreBuilds(), ['x86_64-pc-windows-gnu --debug']);
    assert.equal(output, path.join(root, 'stage/x86_64-pc-windows-gnu'));
  });
});

test('Windows tool setup skips optional NSIS and preserves its version switch in Git Bash', { timeout: 20000 }, async () => {
  const action = await readFile(path.join(scripts, '../../.github/actions/setup-desktop-windows-build-tools/action.yml'), 'utf8');
  const body = action.split('      run: |\n')[1].split('\n').map(line => line.slice(8)).join('\n');
  for (const location of ['disabled', 'path', 'x86', 'x64']) {
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
        gcc: 'printf "fixture gcc\\n"',
        choco: 'echo "unexpected install" >&2; exit 1',
        cygpath: 'printf "%s\\n" "$2"',
      };
      for (const [name, content] of Object.entries(commands)) {
        await writeFile(path.join(bin, name), `#!/usr/bin/env bash\n${content}\n`, { mode: 0o755 });
      }
      if (location !== 'disabled') {
        await writeFile(nsis, '#!/usr/bin/env bash\nset -eu\n[[ "${MSYS2_ARG_CONV_EXCL:-}" == /VERSION && "$#" == 1 && "$1" == /VERSION ]] || { echo "NSIS version switch was not protected from path conversion" >&2; exit 1; }\nprintf "v3.11\\n"\n', { mode: 0o755 });
      }
      // Force the fallback layouts even if the machine has another NSIS installation.
      const commandLookup = location === 'path' ? '' : 'command() { if [[ "$1" == -v && "$2" == makensis ]]; then return 1; fi; builtin command "$@"; }\n';
      const script = commandLookup + body.replaceAll('/c/Program Files (x86)/NSIS', x86).replaceAll('/c/Program Files/NSIS', x64);
      const result = await runProcess({
        command: 'bash', args: ['-e', '-o', 'pipefail', '-c', script], cwd: root,
        env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, GITHUB_PATH: path.join(root, 'github-path'), MSYS2_ARG_CONV_EXCL: '', SETUP_NSIS: location === 'disabled' ? 'false' : 'true' },
        timeoutMs: 4000, maxCapturedBytes: 65536,
      });
      assert.equal(result.timedOut, false);
      assert.equal(result.terminationConfirmed, true);
      assert.equal(result.code, 0, `${location}: ${result.stderr}`);
      assert.match(result.stdout, /fixture gcc/);
      if (location === 'disabled') {
        assert.doesNotMatch(result.stdout, /v3\.11/);
      } else {
        assert.match(result.stdout, /v3\.11/);
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});
