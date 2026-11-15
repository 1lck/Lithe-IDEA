import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { runProcess } from '../../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

// Only the canonical v<version>.md exists. A desktop-v tag must resolve that
// document, while missing/invalid notes and a different manifest still block release.
async function resolveFixture(requested, { notes = true, manifest = '1.2.3', invalid = false } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe-release-version-'));
  try {
    for (const dir of ['scripts/ci/desktop-release', 'scripts/release/notes', 'docs/releases', 'desktop']) {
      await mkdir(path.join(root, dir), { recursive: true });
    }
    await copyFile(new URL('./resolve-release-version.sh', import.meta.url), path.join(root, 'scripts/ci/desktop-release/resolve-release-version.sh'));
    await copyFile(new URL('../../release/notes/validate-stable-release-notes.mjs', import.meta.url), path.join(root, 'scripts/release/notes/validate-stable-release-notes.mjs'));
    await writeFile(path.join(root, 'desktop/viva.toml'), `[app]\nversion = "${manifest}"\n`);
    if (notes) {
      const headings = ['## 中文', '### 下载', '### 重点更新', '### 升级说明', '### 兼容性与已知问题', '## English', '### Downloads', '### Highlights', '### Upgrade instructions', '### Compatibility and known issues'];
      const content = invalid ? ' ' : headings.map(h => `${h}\n\nFixture release information.\n`).join('\n');
      await writeFile(path.join(root, 'docs/releases/v1.2.3.md'), content);
    }
    const output = path.join(root, 'outputs');
    const result = await runProcess({ command: 'bash', args: ['scripts/ci/desktop-release/resolve-release-version.sh', requested], cwd: root,
      env: { ...process.env, GITHUB_OUTPUT: output }, timeoutMs: 10000, maxCapturedBytes: 32768 });
    assert.equal(result.timedOut, false);
    assert.equal(result.terminationConfirmed, true);
    return { ...result, output: result.code === 0 ? await readFile(output, 'utf8') : '' };
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

for (const requested of ['1.2.3', 'desktop-v1.2.3']) {
  test(`release ${requested} reads canonical notes and resolves its tag`, { timeout: 20000 }, async () => {
    const result = await resolveFixture(requested);
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.output, /^version=1\.2\.3\ntag=desktop-v1\.2\.3\n$/);
  });
}
for (const [name, options] of [['missing notes', { notes: false }], ['invalid notes', { invalid: true }], ['manifest mismatch', { manifest: '1.2.4' }]]) {
  test(`release refuses ${name}`, { timeout: 20000 }, async () => {
    const result = await resolveFixture('desktop-v1.2.3', options);
    assert.notEqual(result.code, 0);
  });
}
