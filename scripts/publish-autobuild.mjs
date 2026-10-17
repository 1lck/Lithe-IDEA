#!/usr/bin/env node
// Note: .agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const releaseTag = 'AutoBuild';
const oldTag = 'preview-0.3.0';
const safeName = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
function digest(file) {
  const hash = createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024);
  const descriptor = fs.openSync(file, 'r');
  try {
    let count;
    while ((count = fs.readSync(descriptor, buffer, 0, buffer.length, null)) > 0) hash.update(buffer.subarray(0, count));
    return hash.digest('hex');
  } finally { fs.closeSync(descriptor); }
}
const numericVersion = value => /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value);
const compareVersion = (a, b) => {
  const left = a.split('.').map(BigInt), right = b.split('.').map(BigInt);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] > right[i] ? 1 : -1;
  return 0;
};

// gh owns networking, redirects and authentication; every call has a deadline.
export function runCommand(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 120_000, killSignal: 'SIGKILL', maxBuffer: 16 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`${command} ${args[0]} failed: ${result.error?.message ?? result.stderr}`);
  return result.stdout;
}
function transient(error) { return /ETIMEDOUT|timed out|HTTP (408|429|5\d\d)|connection reset|TLS handshake timeout|network is unreachable/i.test(error.message); }
export function ghCommand(args, run = runCommand, beforeAttempt = () => {}) {
  for (let attempt = 0; attempt < 3; attempt++) {
    beforeAttempt();
    try { return run('gh', args); } catch (error) { if (attempt === 2 || !transient(error)) throw error; }
  }
}

export function selectPlugins(registry, index) {
  if (registry.schemaVersion !== 1 || index.schemaVersion !== 1 || !Array.isArray(registry.plugins) || !Array.isArray(index.plugins)) throw new Error('Unsupported marketplace schema');
  const selected = new Map();
  const ids = new Set();
  for (const registered of registry.plugins) {
    if (ids.has(registered.id)) throw new Error(`Duplicate official plugin ${registered.id}`);
    ids.add(registered.id);
    const entries = index.plugins.filter(plugin => plugin.id === registered.id);
    if (entries.length !== 1) throw new Error(`Missing or duplicate indexed official plugin ${registered.id}`);
    const versions = entries[0].versions.filter(version => numericVersion(version.version) && Array.isArray(version.downloads) && version.downloads.length > 0)
      .sort((a, b) => compareVersion(b.version, a.version));
    if (versions.length === 0) throw new Error(`No downloadable numeric version for ${registered.id}`);
    const latest = versions[0];
    for (const download of latest.downloads) {
      const url = new URL(download.downloadURL);
      const match = url.pathname.match(/^\/Lithe-IDEA\/([^/]+)\/releases\/download\/([^/]+)\/([^/]+)$/);
      if (url.origin !== 'https://github.com' || url.search || url.hash || !match || match[2] !== `${registered.tagPrefix}${latest.version}` || !safeName.test(match[3]) || !match[3].endsWith('.zip') || !/^[a-f0-9]{64}$/.test(download.sha256)) throw new Error(`Untrusted official plugin download: ${download.downloadURL}`);
      const item = { name: match[3], repository: `Lithe-IDEA/${match[1]}`, tag: match[2], sha256: download.sha256 };
      const previous = selected.get(item.name);
      if (previous && JSON.stringify(previous) !== JSON.stringify(item)) throw new Error(`Conflicting plugin asset ${item.name}`);
      selected.set(item.name, item);
    }
  }
  return [...selected.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function validateBuildIdentity(build, timestamp) {
  if (typeof timestamp !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(timestamp)) throw new Error('Invalid AutoBuild ISO timestamp');
  const time = new Date(timestamp);
  if (!Number.isFinite(time.getTime()) || time.toISOString() !== timestamp.replace('Z', '.000Z')) throw new Error('Invalid AutoBuild ISO timestamp');
  const expected = timestamp.slice(0, 10).replaceAll('-', '') + '.' + timestamp.slice(11, 19).replaceAll(':', '');
  if (build !== expected) throw new Error('AutoBuild identity must match ISO timestamp exactly');
  return `AutoBuild — 构建自 ${timestamp.replace('T', ' ').slice(0, 19)} UTC`;
}

function releaseNotes({ source, build, timestamp, version }) {
  return `${validateBuildIdentity(build, timestamp)}\n\n⚠️ 风险提示：AutoBuild 是未经稳定版验证的自动构建，可能包含缺陷或导致数据丢失。普通用户建议使用 Stable 稳定版。\n\n⚠️ Risk warning: AutoBuild is an automatically built prerelease and may contain bugs or cause data loss. Ordinary users should use the Stable release.\n\nSource: ${source}\nVersion: ${version}\nBuild: ${build}\n\nOnly the latest installers, current Sparkle full updates/deltas and latest official downloadable plugins are kept. Plugin ZIPs are byte-identical mirrors; the marketplace index and canonical upstream URLs remain authoritative. Older preview-0.3.0 clients must manually reinstall AutoBuild once. Windows installers may be unsigned when Authenticode is not configured.\n`;
}

export function publishAutoBuild(config, { run = runCommand } = {}) {
  const { repository, source, build, timestamp, version, dist, runnerTemp } = config;
  const title = validateBuildIdentity(build, timestamp);
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository) || !/^[a-f0-9]{40}$/.test(source) || !/^\d+\.\d+$/.test(build) || !numericVersion(version)) throw new Error('Invalid publication identity');
  const root = fs.mkdtempSync(path.join(path.resolve(runnerTemp), 'lithe-autobuild-'));
  const gh = args => ghCommand(args, run);
  const api = endpoint => JSON.parse(gh(['api', endpoint]));
  const optional = endpoint => { try { return api(endpoint); } catch (error) { if (/HTTP 404/.test(error.message)) return null; throw error; } };
  const list = id => JSON.parse(gh(['api', '--paginate', '--slurp', `repos/${repository}/releases/${id}/assets?per_page=100`])).flat();
  const files = new Map();
  function add(file) {
    const name = path.basename(file);
    if (!safeName.test(name) || files.has(name) || !fs.lstatSync(file).isFile() || fs.statSync(file).size === 0) throw new Error(`Invalid or duplicate publication asset ${name}`);
    files.set(name, { file, sha256: digest(file), size: fs.statSync(file).size });
  }
  function checksum(file) {
    const expected = fs.readFileSync(`${file}.sha256`, 'utf8').trim().split(/\s+/)[0];
    if (expected !== digest(file)) throw new Error(`Checksum mismatch: ${path.basename(file)}`);
    add(file); add(`${file}.sha256`);
  }
  try {
    // Execute only workflow-revision code; read source catalog without checkout.
    const marketplace = path.join(root, 'marketplace');
    fs.mkdirSync(marketplace);
    run('git', ['fetch', '--no-tags', '--depth=1', 'origin', source]);
    for (const name of ['official-plugins.json', 'index.json']) fs.writeFileSync(path.join(marketplace, name), run('git', ['show', `${source}:Plugins/marketplace/${name}`]));
    const plugins = selectPlugins(JSON.parse(fs.readFileSync(path.join(marketplace, 'official-plugins.json'))), JSON.parse(fs.readFileSync(path.join(marketplace, 'index.json'))));
    for (const platform of ['arm64', 'x86_64', 'windows-x64']) {
      const identity = JSON.parse(fs.readFileSync(path.join(dist, `identity-${platform}.json`)));
      if (identity.source !== source || identity.build !== build || identity.version !== version || identity.timestamp !== timestamp) throw new Error(`Artifact identity mismatch: ${platform}`);
      checksum(path.join(dist, `Lithe-${version}-${platform}.${platform === 'windows-x64' ? 'exe' : 'dmg'}`));
    }
    const prefix = `https://github.com/${repository}/releases/download/${releaseTag}/`;
    for (const architecture of ['arm64', 'x86_64']) {
      const directory = path.join(dist, `sparkle-${architecture}`);
      const feed = path.join(directory, `appcast-preview-${architecture}.xml`);
      run('ruby', ['scripts/verify-sparkle-appcast.rb', feed, build, timestamp]);
      const xml = fs.readFileSync(feed, 'utf8');
      const names = [...xml.matchAll(/<enclosure\b[^>]*\burl=(["'])(.*?)\1/g)].map(match => {
        if (!match[2].startsWith(prefix)) throw new Error('Appcast must reference AutoBuild');
        const name = match[2].slice(prefix.length);
        // Sparkle derives delta names from CFBundleName; preview bundles use Lithe-Dev.
        const isCurrentDelta = ['Lithe', 'Lithe-Dev'].some(appName => name.startsWith(`${appName}${build}-`)) && name.endsWith(`-${architecture}.delta`);
        if (!safeName.test(name) || !(name === `Lithe-preview-${build}-${architecture}.zip` || isCurrentDelta)) throw new Error(`Unexpected appcast asset ${name}`);
        return name;
      });
      if (!names.includes(`Lithe-preview-${build}-${architecture}.zip`)) throw new Error('Appcast is missing current full archive');
      for (const name of new Set(names)) add(path.join(directory, name));
      add(feed);
    }
    const pluginDirectory = path.join(root, 'plugins'); fs.mkdirSync(pluginDirectory);
    for (const plugin of plugins) {
      const file = path.join(pluginDirectory, plugin.name);
      ghCommand(['release', 'download', plugin.tag, '--repo', plugin.repository, '--pattern', plugin.name, '--dir', pluginDirectory], run, () => {
        // Exact mkdtemp-owned basename; never remove shared caches or worktrees.
        fs.rmSync(file, { force: true });
      });
      if (digest(file) !== plugin.sha256) throw new Error(`Plugin SHA-256 mismatch: ${plugin.name}`);
      fs.writeFileSync(`${file}.sha256`, `${plugin.sha256}  ${plugin.name}\n`);
      add(file); add(`${file}.sha256`);
    }
    // This checkpoint commits the complete target before any installer/feed write.
    // Equal timestamps may resume only when this exact plan is already published.
    const checkpointName = 'autobuild-publication.json';
    const checkpointFile = path.join(root, checkpointName);
    fs.writeFileSync(checkpointFile, JSON.stringify({
      schemaVersion: 1, repository, source, build, timestamp, version,
      assets: [...files].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
        .map(([name, { sha256, size }]) => ({ name, sha256, size })),
    }) + '\n');
    add(checkpointFile);
    // No mutation until every local asset and upstream ZIP passes validation.
    let release = optional(`repos/${repository}/releases/tags/${releaseTag}`);
    // A partially created AutoBuild release must not hide the legacy time baseline.
    const baselines = [[releaseTag, release], [oldTag, optional(`repos/${repository}/releases/tags/${oldTag}`)]];
    let resume = false;
    for (const [baselineTag, baselineRelease] of baselines) {
      if (!baselineRelease) continue;
      const assets = list(baselineRelease.id);
      const baselineDirectory = path.join(root, 'baselines', baselineTag); fs.mkdirSync(baselineDirectory, { recursive: true });
      const checkpoints = baselineTag === releaseTag ? assets.filter(asset => asset.name === checkpointName) : [];
      if (checkpoints.length > 1) throw new Error('Invalid AutoBuild publication checkpoint');
      if (checkpoints.length === 1 && checkpoints[0].state === 'uploaded') {
        const file = path.join(baselineDirectory, checkpointName);
        ghCommand(['release', 'download', releaseTag, '--repo', repository, '--pattern', checkpointName, '--dir', baselineDirectory], run, () => fs.rmSync(file, { force: true }));
        const previous = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (previous.schemaVersion !== 1 || previous.repository !== repository || !/^[a-f0-9]{40}$/.test(previous.source) || !numericVersion(previous.version) || !Array.isArray(previous.assets)) throw new Error('Invalid AutoBuild publication checkpoint');
        validateBuildIdentity(previous.build, previous.timestamp);
        resume = digest(file) === files.get(checkpointName).sha256;
        if (!resume && previous.timestamp >= timestamp) throw new Error('Conflicting AutoBuild publication: checkpoint is newer or has different content at the same timestamp');
      }
      const resumingBaseline = baselineTag === releaseTag && resume;
      for (const architecture of ['arm64', 'x86_64']) {
        const name = `appcast-preview-${architecture}.xml`;
        const matches = assets.filter(asset => asset.name === name);
        if (matches.length === 0) {
          // A prior validated checkpoint also covers a clobber interrupted after deletion.
          if (!resumingBaseline && assets.some(asset => asset.name.startsWith('Lithe-preview-') && asset.name.endsWith(`-${architecture}.zip`))) throw new Error(`Missing published appcast baseline: ${architecture}`);
          continue;
        }
        if (matches.length !== 1) throw new Error(`Invalid published appcast baseline: ${architecture}`);
        if (matches[0].state !== 'uploaded') {
          if (resumingBaseline && matches[0].state === 'starter' && matches[0].size === 0) continue;
          throw new Error(`Invalid published appcast baseline: ${architecture}`);
        }
        const file = path.join(baselineDirectory, name);
        ghCommand(['release', 'download', baselineTag, '--repo', repository, '--pattern', name, '--dir', baselineDirectory], run, () => fs.rmSync(file, { force: true }));
        const mode = resumingBaseline && digest(file) === files.get(name).sha256 ? '--feed' : '--baseline';
        run('ruby', ['scripts/autobuild-identity.rb', mode, file, build, timestamp]);
      }
    }
    const notes = path.join(root, 'notes.md'); fs.writeFileSync(notes, releaseNotes(config));
    if (!release) {
      gh(['release', 'create', releaseTag, '--repo', repository, '--target', source, '--title', title, '--notes-file', notes, '--prerelease', '--latest=false']);
      release = api(`repos/${repository}/releases/tags/${releaseTag}`);
    }
    if (!resume) gh(['release', 'upload', releaseTag, checkpointFile, '--repo', repository, '--clobber']);
    for (const xml of [false, true]) {
      for (const [name, asset] of files) if (name !== checkpointName && name.endsWith('.xml') === xml) gh(['release', 'upload', releaseTag, asset.file, '--repo', repository, '--clobber']);
    }
    const verification = path.join(root, 'verification'); fs.mkdirSync(verification);
    function verifyRemote(assets) {
      for (const [name, local] of files) {
        const matches = assets.filter(asset => asset.name === name && asset.state === 'uploaded');
        if (matches.length !== 1 || matches[0].size !== local.size) throw new Error(`Published asset missing or incomplete: ${name}`);
        const remote = matches[0];
        if (remote.digest) {
          if (remote.digest !== `sha256:${local.sha256}`) throw new Error(`Published digest mismatch: ${name}`);
        } else {
          const file = path.join(verification, name);
          ghCommand(['release', 'download', releaseTag, '--repo', repository, '--pattern', name, '--dir', verification], run, () => fs.rmSync(file, { force: true }));
          if (digest(file) !== local.sha256) throw new Error(`Published bytes mismatch: ${name}`);
        }
      }
    }
    const assets = list(release.id); verifyRemote(assets);
    // target_commitish does not move an existing tag; explicitly update the ref.
    gh(['api', '--method', 'PATCH', `repos/${repository}/git/refs/tags/${releaseTag}`, '-f', `sha=${source}`, '-F', 'force=true']);
    gh(['release', 'edit', releaseTag, '--repo', repository, '--target', source, '--title', title, '--notes-file', notes, '--prerelease', '--latest=false']);
    const ref = api(`repos/${repository}/git/ref/tags/${releaseTag}`);
    const published = api(`repos/${repository}/releases/tags/${releaseTag}`);
    if (ref.object.sha !== source || published.name !== title || !published.prerelease || published.draft) throw new Error('AutoBuild metadata verification failed');
    for (const asset of assets) if (!files.has(asset.name)) gh(['api', '--method', 'DELETE', `repos/${repository}/releases/assets/${asset.id}`]);
    const finalAssets = list(release.id); verifyRemote(finalAssets);
    if (finalAssets.length !== files.size) throw new Error('Stale AutoBuild assets remain');
    const legacy = optional(`repos/${repository}/releases/tags/${oldTag}`);
    if (legacy) gh(['api', '--method', 'DELETE', `repos/${repository}/releases/${legacy.id}`]);
    if (optional(`repos/${repository}/git/ref/tags/${oldTag}`)) gh(['api', '--method', 'DELETE', `repos/${repository}/git/refs/tags/${oldTag}`]);
    return [...files.keys()].sort();
  } finally {
    // mkdtemp owns this exact directory, never a shared cache or worktree.
    fs.rmSync(root, { recursive: true, force: true });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const names = publishAutoBuild({ repository: process.env.GITHUB_REPOSITORY, source: process.env.SOURCE_SHA, build: process.env.PREVIEW_BUILD, timestamp: process.env.LITHE_BUILD_TIMESTAMP, version: process.env.LITHE_VERSION, dist: path.resolve('dist'), runnerTemp: process.env.RUNNER_TEMP });
    console.log(`Verified ${releaseTag}: ${names.join(', ')}`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
