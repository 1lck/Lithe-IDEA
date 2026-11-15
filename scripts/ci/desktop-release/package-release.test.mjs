import assert from 'node:assert/strict';
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { runProcess } from '../../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

async function linuxRelease(arch, wrongRPM = false) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe-release-package-'));
  try {
    for (const dir of ['scripts/ci/desktop-release', 'scripts/ci/common', 'scripts/desktop', 'desktop', 'bin']) {
      await mkdir(path.join(root, dir), { recursive: true });
    }
    await copyFile(new URL('./package-release.sh', import.meta.url), path.join(root, 'scripts/ci/desktop-release/package-release.sh'));
    await copyFile(new URL('../common/desktop-packages.mjs', import.meta.url), path.join(root, 'scripts/ci/common/desktop-packages.mjs'));
    await writeFile(path.join(root, 'desktop/viva.toml'), '[app]\nversion = "0.7.0"\n');
    const executables = {
      'bin/go': '#!/bin/bash\nif [[ "$1" == env ]]; then echo linux; else echo "build -tags=lithe_stable"; fi\n',
      'bin/file': '#!/bin/bash\necho "ELF $FIXTURE_MACHINE"\n',
      'bin/strings': '#!/bin/bash\necho \'version = "0.7.0"\'\n',
      'bin/dpkg-deb': '#!/bin/bash\nif [[ "$3" == Version ]]; then echo 0.7.0; else echo "$FIXTURE_ARCH"; fi\n',
      'bin/rpm': '#!/bin/bash\nif [[ "$1" == --checksig ]]; then exit 0; fi\necho "$FIXTURE_RPM_VERSION 1 $FIXTURE_RPM_ARCH"\n',
      'scripts/desktop/package-desktop.sh': `#!/bin/bash
set -eu
printf '%s\\n' "$*" > "$FIXTURE_ROOT/package-args"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --format) formats="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out" "$FIXTURE_ROOT/tar/lithe-0.7.0-linux-$FIXTURE_ARCH"
printf program > "$FIXTURE_ROOT/tar/lithe-0.7.0-linux-$FIXTURE_ARCH/lithe"
tar -czf "$out/lithe-0.7.0-linux-$FIXTURE_ARCH.tar.gz" -C "$FIXTURE_ROOT/tar" "lithe-0.7.0-linux-$FIXTURE_ARCH"
printf deb > "$out/lithe_0.7.0_$FIXTURE_ARCH.deb"
if [[ ",$formats," == *,rpm,* ]]; then
  printf rpm > "$out/lithe-0.7.0-1.$FIXTURE_RPM_ARCH.rpm"
fi
`,
    };
    for (const [name, source] of Object.entries(executables)) {
      await writeFile(path.join(root, name), source);
      await chmod(path.join(root, name), 0o755);
    }
    const env = { ...process.env, PATH: `${root}/bin${path.delimiter}${process.env.PATH}`,
      FIXTURE_ROOT: root, FIXTURE_ARCH: arch, FIXTURE_MACHINE: arch === 'amd64' ? 'x86-64' : 'aarch64',
      FIXTURE_RPM_ARCH: arch === 'amd64' ? 'x86_64' : 'aarch64', FIXTURE_RPM_VERSION: wrongRPM ? '0.6.0' : '0.7.0' };
    delete env.GITHUB_REF_TYPE;
    const result = await runProcess({ command: 'bash', args: ['scripts/ci/desktop-release/package-release.sh', arch, '0.7.0'],
      cwd: root, env, timeoutMs: 10000, maxCapturedBytes: 65536 });
    assert.equal(result.timedOut, false);
    assert.equal(result.terminationConfirmed, true);
    if (wrongRPM) {
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, /RPM metadata/);
    } else {
      assert.equal(result.code, 0, result.stderr);
      assert.match(await readFile(path.join(root, 'package-args'), 'utf8'), /--format tar.gz,deb,rpm/);
      assert.match(result.stdout, /\.deb\.sha256/);
      assert.match(result.stdout, /\.rpm\.sha256/);
      assert.match(result.stdout, /\.tar.gz\.sha256/);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}
for (const arch of ['amd64', 'arm64']) {
  test(`Linux ${arch} Release packages and checks all three formats`, { timeout: 20000 }, () => linuxRelease(arch));
}
test('Release refuses mismatched RPM metadata', { timeout: 20000 }, () => linuxRelease('amd64', true));
