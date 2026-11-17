import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { access, chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { packageNames } from '../common/desktop-packages.mjs';
import { runProcess } from '../../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const REPO = 'example/lithe';
const sha256 = (text) => createHash('sha256').update(text).digest('hex');

// A fake gh serves releases from <root>/releases/<tag>/ and logs each call with whether it could
// see the signing key; uploads are listed in order. A fake viva records its arguments and writes
// a feed, its signature and one patch per -patch-from. The tool script hands out the fake viva.
const executables = {
  'bin/gh': `#!/bin/bash
set -eu
key=no
if [[ -n "\${VIVA_UPDATE_KEY:-}" ]]; then key=yes; fi
printf '%s key=%s\\n' "$*" "$key" >> "$FIXTURE_ROOT/gh-log"
releases="$FIXTURE_ROOT/releases"
command="$2" tag="$3"
shift 3
patterns=() files=() dir="" json=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--title|--notes|--target|--jq) shift 2 ;;
    --json) json=yes; shift 2 ;;
    --pattern) patterns+=("$2"); shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --*) shift ;;
    *) files+=("$1"); shift ;;
  esac
done
if [[ "$command" == view && -n "\${FIXTURE_VIEW_ERROR:-}" ]]; then printf '%s\\n' "$FIXTURE_VIEW_ERROR" >&2; exit 1; fi
if [[ "$command" != create && ! -d "$releases/$tag" ]]; then printf '%s\\n' 'release not found' >&2; exit 1; fi
case "$command" in
  view) if [[ "$json" == yes ]]; then ls "$releases/$tag"; fi ;;
  download)
    found=no
    for pattern in "\${patterns[@]}"; do
      if [[ -f "$releases/$tag/$pattern" ]]; then cp "$releases/$tag/$pattern" "$dir/"; found=yes; fi
    done
    if [[ "$found" == no ]]; then printf '%s\\n' 'no assets match the file pattern' >&2; exit 1; fi ;;
  upload)
    for file in "\${files[@]}"; do
      cp "$file" "$releases/$tag/"
      printf '%s %s\\n' "$tag" "$(basename "$file")" >> "$FIXTURE_ROOT/uploads"
    done ;;
  create) mkdir -p "$releases/$tag" ;;
esac
`,
  'bin/viva': `#!/bin/bash
set -eu
key=no
if [[ -n "\${VIVA_UPDATE_KEY:-}" ]]; then key=yes; fi
printf '%s\\n' "$key" > "$FIXTURE_ROOT/viva-key"
printf '%s\\n' "$@" > "$FIXTURE_ROOT/viva-args"
dir="" out="" version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -dir) dir="$2"; shift 2 ;;
    -out) out="$2"; shift 2 ;;
    -version) version="$2"; shift 2 ;;
    -patch-from)
      platform="\${2%%=*}" rest="\${2#*=}"
      from="\${rest%%=*}" os="\${platform%/*}" arch="\${platform#*/}"
      for archive in "$dir/lithe-$version-$os-$arch.zip" "$dir/lithe-$version-$os-$arch.tar.gz"; do
        if [[ -f "$archive" ]]; then printf patch > "$archive.$from.patch"; fi
      done
      shift 2 ;;
    *) shift ;;
  esac
done
ls "$dir" | grep -v '\\.patch$' > "$FIXTURE_ROOT/viva-archives"
printf '{"version":"%s"}\\n' "$version" > "$out"
printf sig > "$out.sig"
`,
  'scripts/desktop/build-viva-tool.sh': `#!/bin/bash
printf '%s\\n' "\${VIVA_UPDATE_KEY:+yes}" > "$FIXTURE_ROOT/tool-key"
printf '%s\\n' "$FIXTURE_ROOT/bin/viva"
`,
};

async function writePackage(dir, name, content = name) {
  await writeFile(path.join(dir, name), content);
  await writeFile(path.join(dir, `${name}.sha256`), `${sha256(content)}  ${name}\n`);
}

// The archives the previous release (0.8.2 unless a test names another) holds: no Intel macOS
// zip, and the rest with their .sha256.
const previousArchives = (previous = '0.8.2') => [`lithe-${previous}-darwin-arm64.zip`,
  `lithe-${previous}-windows-amd64.zip`, `lithe-${previous}-linux-amd64.tar.gz`, `lithe-${previous}-linux-arm64.tar.gz`];

// A stable feed offering version; for the previous release it lists that release's archives'
// digests, all right but the Linux arm64 one, and for another version patches from 0.8.2.
function stableFeed(version, app = 'app.lithe.viva', previous = version === '0.9.0' || version === '1.0.0' ? '0.8.2' : version) {
  const assets = previousArchives(previous).map((name) => {
    const [, os, arch] = /-(darwin|windows|linux)-(amd64|arm64)\./.exec(name);
    const digest = name.includes('linux-arm64') ? '0'.repeat(64) : sha256(name);
    return version === previous
      ? { os, arch, url: `https://github.com/${REPO}/releases/download/desktop-v${previous}/${name}`, sha256: digest }
      : { os, arch, url: `https://github.com/${REPO}/releases/download/desktop-v${version}/${name.replace(previous, version)}`,
        sha256: '1'.repeat(64), patches: [{ from_version: previous, url: 'https://example.invalid/p', sha256: '2'.repeat(64) }] };
  });
  return JSON.stringify({ schema: 1, app, channel: 'stable', latest: { version, assets } });
}

async function publish({ feed, key = 'c2VjcmV0', viewError, previous = '0.8.2' } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe-update-feed-'));
  try {
    for (const dir of ['scripts/ci/desktop-release', 'scripts/ci/common', 'scripts/desktop', 'desktop', 'docs/releases',
      'bin', 'dist', 'releases/desktop-v0.9.0', `releases/desktop-v${previous}`]) {
      await mkdir(path.join(root, dir), { recursive: true });
    }
    await copyFile(new URL('./publish-update-feed.sh', import.meta.url), path.join(root, 'scripts/ci/desktop-release/publish-update-feed.sh'));
    await copyFile(new URL('../common/desktop-packages.mjs', import.meta.url), path.join(root, 'scripts/ci/common/desktop-packages.mjs'));
    await writeFile(path.join(root, 'desktop/viva.toml'), '[app]\nname = "Lithe"\nid = "app.lithe.viva"\nversion = "0.9.0"\n');
    await writeFile(path.join(root, 'docs/releases/v0.9.0.md'), '## 中文\n\n新功能。\n\n## English\n\nNew things.\n');
    for (const [file, content] of Object.entries(executables)) {
      await writeFile(path.join(root, file), content);
      await chmod(path.join(root, file), 0o755);
    }
    for (const name of packageNames('0.9.0')) await writePackage(path.join(root, 'dist'), name);
    for (const name of previousArchives(previous)) await writePackage(path.join(root, `releases/desktop-v${previous}`), name);
    if (feed) {
      await mkdir(path.join(root, 'releases/desktop-update-feed'));
      await writeFile(path.join(root, 'releases/desktop-update-feed/stable.json'), feed);
    }
    const env = { ...process.env, PATH: `${root}/bin${path.delimiter}${process.env.PATH}`, FIXTURE_ROOT: root,
      GH_TOKEN: 'token', GITHUB_REPOSITORY: REPO, DESKTOP_VERSION: '0.9.0', RELEASE_TAG: 'desktop-v0.9.0', GITHUB_SHA: 'abc1234' };
    for (const name of ['VIVA_UPDATE_KEY', 'GITHUB_STEP_SUMMARY', 'FIXTURE_VIEW_ERROR']) delete env[name];
    if (key) env.VIVA_UPDATE_KEY = key;
    if (viewError) env.FIXTURE_VIEW_ERROR = viewError;
    const result = await runProcess({ command: 'bash', args: ['scripts/ci/desktop-release/publish-update-feed.sh', 'dist'],
      cwd: root, env, timeoutMs: 15000, maxCapturedBytes: 65536 });
    assert.equal(result.timedOut, false);
    assert.equal(result.terminationConfirmed, true);
    const read = (file) => readFile(path.join(root, file), 'utf8').catch(() => '');
    return { ...result, root, read, exists: (file) => access(path.join(root, file)).then(() => true, () => false) };
  } catch (error) {
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

async function check(options, body) {
  const run = await publish(options);
  try {
    await body(run);
  } finally {
    await rm(run.root, { recursive: true, force: true });
  }
}

// Each published file is copied whole, so the key reaching anything but viva would show here.
async function assertKeyReachesVivaAlone(run) {
  assert.equal((await run.read('viva-key')).trim(), 'yes');
  assert.doesNotMatch(await run.read('gh-log'), /key=yes/);
  assert.equal((await run.read('tool-key')).trim(), '');
}

test('without a signing key nothing is published', { timeout: 30000 }, () => check({ key: '' }, async (run) => {
  assert.equal(run.code, 0, run.stderr);
  assert.match(run.stdout, /VIVA_UPDATE_KEY is not set/);
  assert.equal(await run.exists('gh-log'), false);
  assert.equal(await run.exists('viva-args'), false);
}));

test('the first stable feed lists the full packages and creates the feed release', { timeout: 30000 }, () => check({}, async (run) => {
  assert.equal(run.code, 0, run.stderr);
  const args = await run.read('viva-args');
  assert.match(args, /^-channel\nstable$/m);
  assert.match(args, new RegExp(`^-base-url\\nhttps://github.com/${REPO}/releases/download/desktop-v0.9.0$`, 'm'));
  assert.doesNotMatch(args, /-patch-from/);
  // The updater installs the macOS zips, the Windows installer and zip and the Linux tar.gz only.
  assert.deepEqual((await run.read('viva-archives')).trim().split('\n').sort(), packageNames('0.9.0')
    .filter((name) => /\.zip$|-setup\.exe$|\.tar\.gz$/.test(name)).sort());
  assert.match(await run.read('gh-log'), /^release create desktop-update-feed [^]*?--prerelease --latest=false --target abc1234 key=no$/m);
  assert.equal(await run.read('uploads'),
    'desktop-update-feed stable.notes.md\ndesktop-update-feed stable.json\ndesktop-update-feed stable.json.sig\n');
  assert.equal(await run.read('releases/desktop-update-feed/stable.notes.md'),
    '<!-- lithe-update-notes version=0.9.0 -->\n## 中文\n\n新功能。\n\n## English\n\nNew things.\n');
  await assertKeyReachesVivaAlone(run);
}));

test('a feed offering the previous version makes delta updates from its verified archives', { timeout: 30000 },
  () => check({ feed: stableFeed('0.8.2') }, async (run) => {
    assert.equal(run.code, 0, run.stderr);
    const args = await run.read('viva-args');
    for (const platform of ['darwin/arm64', 'windows/amd64', 'linux/amd64']) {
      assert.match(args, new RegExp(`^${platform}=0\\.8\\.2=.*lithe-0\\.8\\.2-${platform.replace('/', '-')}\\.(zip|tar\\.gz)$`, 'm'));
    }
    // Intel macOS has no previous archive and the Linux arm64 one differs from the feed.
    assert.doesNotMatch(args, /darwin\/amd64=|linux\/arm64=/);
    assert.match(run.stdout, /::warning::No delta update for darwin\/amd64: .* could not be downloaded/);
    assert.match(run.stdout, /::warning::No delta update for linux\/arm64: .* does not match/);
    // The patches are up before the feed that lists them, and the feed release is reused.
    assert.equal(await run.read('uploads'), [
      'desktop-v0.9.0 lithe-0.9.0-darwin-arm64.zip.0.8.2.patch',
      'desktop-v0.9.0 lithe-0.9.0-linux-amd64.tar.gz.0.8.2.patch',
      'desktop-v0.9.0 lithe-0.9.0-windows-amd64.zip.0.8.2.patch',
      'desktop-update-feed stable.notes.md', 'desktop-update-feed stable.json', 'desktop-update-feed stable.json.sig', ''].join('\n'));
    assert.doesNotMatch(await run.read('gh-log'), /release create/);
    await assertKeyReachesVivaAlone(run);
  }));

// Lithe 0.8.0 and 0.8.1 delete a rebuilt Windows application before the updater's helper copies
// it, so a Windows patch from either quits Lithe without updating it (vivaui/viva#334). Their
// users get the full installer, which 0.8.1 installs (0.8.0 cannot update itself on Windows).
for (const previous of ['0.8.0', '0.8.1']) {
  test(`a Windows client of ${previous} gets the full installer, not a patch`, { timeout: 30000 },
    () => check({ feed: stableFeed(previous), previous }, async (run) => {
      assert.equal(run.code, 0, run.stderr);
      const args = await run.read('viva-args');
      assert.doesNotMatch(args, /windows\/amd64=/);
      for (const platform of ['darwin/arm64', 'linux/amd64']) {
        assert.match(args, new RegExp(`^${platform}=${previous.replaceAll('.', '\\.')}=`, 'm'));
      }
      assert.match(run.stdout, new RegExp(`::notice::No delta update for windows/amd64 from ${previous.replaceAll('.', '\\.')}:`));
      assert.doesNotMatch(await run.read('uploads'), /windows-amd64\.zip\.[0-9.]+\.patch/);
      // The installer and the zip are still listed, so the client downloads the installer.
      assert.match(await run.read('viva-archives'), /^lithe-0\.9\.0-windows-amd64-setup\.exe$/m);
    }));
}

test('publishing the offered version again patches from the same version', { timeout: 30000 },
  () => check({ feed: stableFeed('0.9.0') }, async (run) => {
    assert.equal(run.code, 0, run.stderr);
    const args = await run.read('viva-args');
    for (const platform of ['darwin/arm64', 'windows/amd64', 'linux/amd64', 'linux/arm64']) {
      assert.match(args, new RegExp(`^${platform}=0\\.8\\.2=`, 'm'));
    }
    assert.match(run.stdout, /Delta updates from 0\.8\.2/);
  }));

test('a feed offering a later version is left as it is', { timeout: 30000 }, () => check({ feed: stableFeed('1.0.0') }, async (run) => {
  assert.equal(run.code, 0, run.stderr);
  assert.match(run.stdout, /already offers 1\.0\.0, later than 0\.9\.0/);
  assert.equal(await run.exists('viva-args'), false);
  assert.equal(await run.exists('uploads'), false);
}));

for (const [name, options] of [
  ['a feed release that cannot be read', { viewError: 'HTTP 502: Bad Gateway' }],
  ['a published feed for another application', { feed: stableFeed('0.8.2', 'app.other') }],
]) {
  test(`${name} fails the run before anything is published`, { timeout: 30000 }, () => check(options, async (run) => {
    assert.notEqual(run.code, 0);
    assert.equal(await run.exists('viva-args'), false);
    assert.equal(await run.exists('uploads'), false);
  }));
}
