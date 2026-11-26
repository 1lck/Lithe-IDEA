// Shared by Desktop Release and AutoBuild: target matrix, formats and download inventory.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const packageTargets = [
  { os: 'darwin', arch: 'arm64', runner: 'macos-26', 'rust-target': 'aarch64-apple-darwin' },
  { os: 'darwin', arch: 'amd64', runner: 'macos-26', 'rust-target': 'x86_64-apple-darwin' },
  { os: 'windows', arch: 'amd64', runner: 'windows-2022', 'rust-target': 'x86_64-pc-windows-gnu' },
  { os: 'linux', arch: 'amd64', runner: 'ubuntu-22.04', 'rust-target': 'x86_64-unknown-linux-gnu' },
  { os: 'linux', arch: 'arm64', runner: 'ubuntu-22.04-arm', 'rust-target': 'aarch64-unknown-linux-gnu' },
];

// Group targets that share the same OS and GitHub Actions runner (e.g. darwin arm64 + amd64 on
// macos-26) into one workflow matrix job so releases request only one macOS runner instead of two.
export function packageMatrix() {
  const grouped = new Map();
  for (const entry of packageTargets) {
    const key = `${entry.os}:${entry.runner}`;
    if (!grouped.has(key)) {
      grouped.set(key, {
        os: entry.os,
        runner: entry.runner,
        arches: [],
        rustTargets: [],
      });
    }
    const group = grouped.get(key);
    group.arches.push(entry.arch);
    group.rustTargets.push(entry['rust-target']);
  }
  return Array.from(grouped.values(), (group) => ({
    os: group.os,
    arch: group.arches.join('-'),
    arches: group.arches.join(' '),
    runner: group.runner,
    'rust-target': group.rustTargets.join(','),
  }));
}

function target(os, arch) {
  const found = packageTargets.find((entry) => entry.os === os && entry.arch === arch);
  if (!found) throw new Error(`Unsupported desktop package target ${os}/${arch}`);
  return found;
}

export function packageFormats(os, arch) {
  target(os, arch);
  return { darwin: 'app,zip,dmg', windows: 'nsis,zip', linux: 'tar.gz,deb,rpm' }[os];
}

export function packageNames(version, os, arch) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Invalid desktop package version');
  if (os === undefined && arch === undefined) {
    return packageTargets.flatMap((entry) => packageNames(version, entry.os, entry.arch));
  }
  target(os, arch);
  const stem = `lithe-${version}-${os}-${arch}`;
  switch (os) {
    case 'darwin': return [`${stem}.dmg`, `${stem}.zip`];
    case 'windows': return [`${stem}-setup.exe`, `${stem}.zip`];
    case 'linux': return [`lithe_${version}_${arch}.deb`,
      `lithe-${version}-1.${arch === 'amd64' ? 'x86_64' : 'aarch64'}.rpm`, `${stem}.tar.gz`];
  }
}

// Validate the flat download directory before any publication side effects. Hash streams keep
// memory bounded even when all five targets' large packages are present on the publisher.
export async function verifyPackages(version, directory) {
  const names = packageNames(version);
  const expected = new Set(names.flatMap((name) => [name, `${name}.sha256`]));
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isFile() || !expected.has(entry.name)) throw new Error(`Unexpected artifact: ${entry.name}`);
  }
  for (const name of expected) {
    if (!entries.some((entry) => entry.name === name)) throw new Error(`Missing artifact: ${name}`);
  }
  for (const name of names) {
    const file = path.join(directory, name);
    if ((await stat(file)).size === 0) throw new Error(`Empty artifact: ${name}`);
    const checksum = await readFile(`${file}.sha256`, 'utf8');
    const match = checksum.match(/^([a-f0-9]{64}) [ *]([^\r\n]+)\r?\n?$/i);
    if (!match || match[2] !== name) throw new Error(`Invalid checksum file: ${name}.sha256`);
    const hash = createHash('sha256');
    for await (const bytes of createReadStream(file)) hash.update(bytes);
    if (hash.digest('hex') !== match[1].toLowerCase()) throw new Error(`Checksum mismatch: ${name}`);
  }
}

async function main([command, ...args]) {
  switch (command) {
    case 'matrix': console.log(JSON.stringify({ include: packageMatrix() })); break;
    case 'formats': console.log(packageFormats(...args)); break;
    case 'names': console.log(packageNames(...args).join('\n')); break;
    case 'verify': await verifyPackages(...args); console.log('Verified all 12 desktop packages and 12 checksums.'); break;
    default: throw new Error('Usage: desktop-packages.mjs matrix | formats OS ARCH | names VERSION [OS ARCH] | verify VERSION DIR');
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => { console.error(error.message); process.exitCode = 1; });
}
