import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { packageMatrix, packageNames, packageTargets, verifyPackages } from './desktop-packages.mjs';

const version = '0.7.0';
test('both channels cover all five targets and twelve downloadable packages', () => {
  assert.deepEqual(packageTargets.map(({ os, arch }) => `${os}/${arch}`),
    ['darwin/arm64', 'darwin/amd64', 'windows/amd64', 'linux/amd64', 'linux/arm64']);
  assert.deepEqual(packageMatrix().map(({ os, arches, runner }) => `${os}:${arches}@${runner}`),
    ['darwin:arm64 amd64@macos-26', 'windows:amd64@windows-2022', 'linux:amd64@ubuntu-22.04', 'linux:arm64@ubuntu-22.04-arm']);
  const names = packageNames(version);
  assert.equal(names.length, 12);
  for (const arch of ['arm64', 'amd64']) {
    for (const format of ['dmg', 'zip']) assert.ok(names.includes(`lithe-${version}-darwin-${arch}.${format}`));
    assert.ok(names.includes(`lithe_${version}_${arch}.deb`));
  }
  assert.ok(names.includes(`lithe-${version}-1.x86_64.rpm`));
  assert.ok(names.includes(`lithe-${version}-1.aarch64.rpm`));
  assert.throws(() => packageNames(version, 'windows', 'arm64'), /Unsupported/);
  assert.throws(() => packageNames('../bad'), /version/);
});

test('publication refuses missing Intel, missing RPM, corrupt or unexpected artifacts', { timeout: 15000 }, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe-artifact-inventory-'));
  try {
    const names = packageNames(version);
    for (const name of names) {
      const bytes = Buffer.from(`package ${name}`);
      await writeFile(path.join(root, name), bytes);
      await writeFile(path.join(root, `${name}.sha256`), `${createHash('sha256').update(bytes).digest('hex')}  ${name}\n`);
    }
    await verifyPackages(version, root);
    for (const name of [`lithe-${version}-darwin-amd64.dmg`, `lithe-${version}-1.aarch64.rpm`]) {
      const bytes = await readFile(path.join(root, name));
      await rm(path.join(root, name));
      await assert.rejects(verifyPackages(version, root), /missing|ENOENT/i);
      await writeFile(path.join(root, name), bytes);
    }
    const name = names[0];
    const bytes = await readFile(path.join(root, name));
    await writeFile(path.join(root, name), 'corrupt');
    await assert.rejects(verifyPackages(version, root), /checksum/i);
    await writeFile(path.join(root, name), bytes);
    await writeFile(path.join(root, 'obsolete.zip'), 'stale');
    await assert.rejects(verifyPackages(version, root), /unexpected/i);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('both workflow matrices and publication gates consume the common package contract', async () => {
  for (const workflow of ['desktop-autobuild', 'desktop-release']) {
    const source = await readFile(new URL(`../../../.github/workflows/${workflow}.yml`, import.meta.url), 'utf8');
    assert.match(source, /matrix: \$\{\{ fromJSON\(needs.prepare.outputs.matrix\) \}\}/);
    assert.match(source, /node scripts\/ci\/common\/desktop-packages.mjs matrix/);
    if (workflow === 'desktop-release') assert.match(source, /desktop-packages.mjs verify/);
    else {
      const publisher = await readFile(new URL('../desktop-autobuild/publish-autobuild.sh', import.meta.url), 'utf8');
      assert.match(publisher, /desktop-packages.mjs" verify/);
      assert.ok(publisher.indexOf('desktop-packages.mjs" verify') < publisher.indexOf('if ! gh release view'));
    }
  }
});
