import assert from 'node:assert/strict';
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { runProcess } from '../../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

async function packageFixture(goos, arch, invalidSignature = false) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe-autobuild-package-'));
  try {
    for (const dir of ['scripts/ci/desktop-autobuild', 'scripts/desktop', 'scripts/ci/common', 'desktop', 'bin']) {
      await mkdir(path.join(root, dir), { recursive: true });
    }
    await copyFile(new URL('./package-autobuild.sh', import.meta.url), path.join(root, 'scripts/ci/desktop-autobuild/package-autobuild.sh'));
    await copyFile(new URL('../common/desktop-packages.mjs', import.meta.url), path.join(root, 'scripts/ci/common/desktop-packages.mjs'));
    await writeFile(path.join(root, 'desktop/viva.toml'), '[app]\nversion = "0.7.0"\n');
    const executables = {
      'bin/go': '#!/bin/bash\nprintf "%s\\n" "$FIXTURE_GOOS"\n',
      'bin/codesign': '#!/bin/bash\nprintf "%s\\n" "$*" > "$FIXTURE_ROOT/signature-check"\nexit "$FIXTURE_SIGNATURE_STATUS"\n',
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
mkdir -p "$out"
if [[ "$FIXTURE_GOOS" == linux ]]; then
  printf tar > "$out/lithe-0.7.0-linux-$FIXTURE_ARCH.tar.gz"
  printf deb > "$out/lithe_0.7.0_$FIXTURE_ARCH.deb"
  if [[ ",$formats," == *,rpm,* ]]; then
    rpm_arch=x86_64
    if [[ "$FIXTURE_ARCH" == arm64 ]]; then rpm_arch=aarch64; fi
    printf rpm > "$out/lithe-0.7.0-1.$rpm_arch.rpm"
  fi
else
  mkdir -p "$out/Lithe Desktop.app"
  printf zip > "$out/lithe-0.7.0-darwin-$FIXTURE_ARCH.zip"
  printf dmg > "$out/lithe-0.7.0-darwin-$FIXTURE_ARCH.dmg"
fi
`,
    };
    for (const [file, content] of Object.entries(executables)) {
      await writeFile(path.join(root, file), content);
      await chmod(path.join(root, file), 0o755);
    }
    const env = { ...process.env, PATH: `${root}/bin${path.delimiter}${process.env.PATH}`,
      FIXTURE_ROOT: root, FIXTURE_GOOS: goos, FIXTURE_ARCH: arch,
      FIXTURE_SIGNATURE_STATUS: invalidSignature ? '1' : '0' };
    for (const name of ['APPLE_CERTIFICATE', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_SIGNING_IDENTITY']) delete env[name];
    const result = await runProcess({ command: 'bash', args: ['scripts/ci/desktop-autobuild/package-autobuild.sh', arch],
      cwd: root, env, timeoutMs: 10000, maxCapturedBytes: 65536 });
    assert.equal(result.timedOut, false);
    assert.equal(result.terminationConfirmed, true);
    if (goos === 'linux') {
      assert.equal(result.code, 0, result.stderr);
      const rpmArch = arch === 'amd64' ? 'x86_64' : 'aarch64';
      assert.match(await readFile(path.join(root, `dist/autobuild/lithe-0.7.0-1.${rpmArch}.rpm.sha256`), 'utf8'), /[a-f0-9]{64}  lithe-/);
      assert.match(result.stdout, /\.deb\n/);
      assert.match(await readFile(path.join(root, 'package-args'), 'utf8'), /--autobuild/);
    } else if (invalidSignature) {
      assert.notEqual(result.code, 0, 'an invalid application signature must block publication');
    } else {
      assert.equal(result.code, 0, result.stderr);
      assert.match(await readFile(path.join(root, 'package-args'), 'utf8'), /--ad-hoc-sign/);
      assert.match(await readFile(path.join(root, 'signature-check'), 'utf8'), /--verify --deep --strict/);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

for (const arch of ['amd64', 'arm64']) {
  test(`Linux ${arch} publishes DEB, RPM and checksums`, { timeout: 20000 }, () => packageFixture('linux', arch));
}
test('macOS without a certificate seals and verifies the app bundle', { timeout: 20000 }, () => packageFixture('darwin', 'arm64'));
test('macOS refuses to publish an invalid app signature', { timeout: 20000 }, () => packageFixture('darwin', 'arm64', true));

test('Intel macOS uses the same formats and signature check', { timeout: 20000 }, () => packageFixture('darwin', 'amd64'));
