import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';
import { fileURLToPath } from 'node:url';
import { runProcess } from '../../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repository = path.resolve(here, '../..');
const script = path.join(here, 'linux.sh');
const feedURL = 'https://github.com/1lck/Lithe-IDEA/releases/download/desktop-update-feed/stable.json';
const version = '9.9.9';
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const releaseURL = (file) => `https://github.com/1lck/Lithe-IDEA/releases/download/desktop-v${version}/${file}`;

// Every library the installer looks for, as ldconfig -p lists them.
const allLibraries = [
  'libxcb.so.1', 'libcairo.so.2', 'libfontconfig.so.1', 'libpango-1.0.so.0', 'libpangocairo-1.0.so.0',
  'libpangoft2-1.0.so.0', 'libgobject-2.0.so.0', 'libxcb-cursor.so.0', 'libxcb-randr.so.0',
  'libxcb-render.so.0', 'libxcb-shape.so.0', 'libxcb-sync.so.1', 'libvulkan.so.1',
];
const ldconfigListing = (libraries) => [`${libraries.length} libs found in cache \`/etc/ld.so.cache'`,
  ...libraries.map((name) => `\t${name} (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/${name}`)].join('\n');

// The fakes shadow the real commands through PATH. uname, id, dpkg-query and rpm answer from
// FAKE_* variables. curl logs each address and serves <root>/www/<address without https://>,
// failing like curl -f for anything else. ldconfig prints <root>/ldconfig.
const executables = {
  uname: `#!/bin/sh
case "$1" in
-s) echo "\${FAKE_UNAME_S:-Linux}" ;;
-m) echo "\${FAKE_UNAME_M:-x86_64}" ;;
*) echo Linux ;;
esac
`,
  id: `#!/bin/sh
echo "\${FAKE_UID:-1000}"
`,
  curl: `#!/bin/sh
out= url=
while [ $# -gt 0 ]; do
  case "$1" in
  -o) out=$2; shift ;;
  --proto | --proto-redir | --retry) shift ;;
  -*) ;;
  *) url=$1 ;;
  esac
  shift
done
printf '%s\\n' "$url" >> "$FIXTURE_ROOT/curl-log"
file="$FIXTURE_ROOT/www/\${url#https://}"
[ -f "$file" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$file" "$out"
`,
  ldconfig: `#!/bin/sh
cat "$FIXTURE_ROOT/ldconfig"
`,
  'dpkg-query': `#!/bin/sh
if [ "\${FAKE_DPKG:-}" = installed ]; then printf 'install ok installed'; exit 0; fi
echo "dpkg-query: no packages found matching lithe" >&2
exit 1
`,
  rpm: `#!/bin/sh
[ "\${FAKE_RPM:-}" = installed ]
`,
};

// The archive's install.sh records how it was called instead of installing.
const bundledInstaller = `#!/bin/sh
printf '%s\\n' "$@" > "$FIXTURE_ROOT/install-args"
echo "installed lithe in $3"
`;

function asset(osName, arch, format, archive) {
  const file = `lithe-${version}-${osName}-${arch}.${format}`;
  return {
    os: osName, arch, format, url: releaseURL(file), size: archive.length, sha256: sha256(archive),
    patches: [{ from_version: '9.9.8', url: releaseURL(`${file}.9.9.8.patch`), size: 3, sha256: sha256('patch') }],
  };
}

async function writeArchive(root, arch) {
  const name = `lithe-${version}-linux-${arch}`;
  const source = path.join(root, arch);
  await mkdir(path.join(source, name), { recursive: true });
  await writeFile(path.join(source, name, 'install.sh'), bundledInstaller, { mode: 0o755 });
  await writeFile(path.join(source, name, 'lithe'), `lithe ${arch}\n`, { mode: 0o755 });
  const archive = path.join(root, `${name}.tar.gz`);
  const result = spawnSync('tar', ['-czf', archive, '-C', source, name],
    { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 10000 });
  assert.equal(result.status, 0, String(result.stderr));
  return readFile(archive);
}

// The two archives are the same in every case, so they are packed once for the file.
let archiveRoot;
let archives;
function packedArchives() {
  archives ??= (async () => {
    archiveRoot = await mkdtemp(path.join(os.tmpdir(), 'lithe-linux-archives-'));
    return { amd64: await writeArchive(archiveRoot, 'amd64'), arm64: await writeArchive(archiveRoot, 'arm64') };
  })();
  return archives;
}
after(() => archiveRoot && rm(archiveRoot, { recursive: true, force: true }));

function www(root, url) {
  return path.join(root, 'www', url.replace(/^https:\/\//, ''));
}

// fixture builds a feed that lists macOS, both Linux and Windows archives, each with a patch,
// so picking the wrong entry or a patch's address shows up in the download log.
async function fixture({ feed: edit = (feed) => feed, minified = false, libraries = allLibraries,
  osRelease = 'ID=ubuntu\nID_LIKE=debian\n', corrupt = false } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lithe-linux-install-'));
  try {
    await mkdir(path.join(root, 'bin'));
    for (const [name, text] of Object.entries(executables)) {
      await writeFile(path.join(root, 'bin', name), text);
      await chmod(path.join(root, 'bin', name), 0o755);
    }
    await mkdir(path.join(root, 'home'));
    await mkdir(path.join(root, 'tmp'));
    await writeFile(path.join(root, 'ldconfig'), ldconfigListing(libraries));
    await writeFile(path.join(root, 'os-release'), osRelease);
    const { amd64, arm64 } = await packedArchives();
    const feed = edit({
      schema: 1, app: 'app.lithe.viva', channel: 'stable',
      latest: {
        version, date: '2026-11-22T00:00:00Z', notes_url: releaseURL('notes'),
        assets: [asset('darwin', 'arm64', 'zip', Buffer.from('mac')), asset('linux', 'amd64', 'tar.gz', amd64),
          asset('linux', 'arm64', 'tar.gz', arm64), asset('windows', 'amd64', 'zip', Buffer.from('win'))],
      },
    });
    const files = new Map([[feedURL, JSON.stringify(feed, null, minified ? undefined : 2)],
      [releaseURL(`lithe-${version}-linux-amd64.tar.gz`), corrupt ? Buffer.from('not the archive') : amd64],
      [releaseURL(`lithe-${version}-linux-arm64.tar.gz`), arm64]]);
    for (const [url, data] of files) {
      await mkdir(path.dirname(www(root, url)), { recursive: true });
      await writeFile(www(root, url), data);
    }
    return root;
  } catch (error) {
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

async function run(root, args = [], env = {}, { pipe = false } = {}) {
  const home = path.join(root, 'home');
  const environment = {
    // Only the system directories after the fakes, so a Lithe on the developer's PATH stays out.
    PATH: `${path.join(root, 'bin')}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: home, TMPDIR: path.join(root, 'tmp'),
    FIXTURE_ROOT: root, LITHE_INSTALL_OS_RELEASE: path.join(root, 'os-release'),
    XDG_DATA_DIRS: '/usr/local/share:/usr/share', ...env,
  };
  // Through a pipe the script arrives on standard input, as with curl | sh.
  const command = pipe ? ['-c', 'cat "$0" | sh -s -- "$@"', script, ...args] : [script, ...args];
  const result = await runProcess({ command: 'sh', args: command, cwd: root, env: environment,
    timeoutMs: 15000, maxCapturedBytes: 65536 });
  assert.equal(result.timedOut, false);
  assert.equal(result.terminationConfirmed, true);
  const read = (file) => readFile(path.join(root, file), 'utf8').catch(() => '');
  return { ...result, home, downloads: (await read('curl-log')).split('\n').filter(Boolean),
    installArgs: (await read('install-args')).split('\n').filter(Boolean),
    leftovers: await readdir(path.join(root, 'tmp')) };
}

async function withFixture(options, body) {
  const root = await fixture(options);
  try {
    await body(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test('installs the x86_64 tar.gz from the feed under ~/.local', { timeout: 30000 }, () =>
  withFixture({}, async (root) => {
    const result = await run(root);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.downloads, [feedURL, releaseURL(`lithe-${version}-linux-amd64.tar.gz`)]);
    assert.deepEqual(result.installArgs, ['install', '--prefix', `${result.home}/.local`]);
    assert.match(result.stdout, /Lithe 9\.9\.9 is installed/);
    assert.match(result.stdout, /\| sh -s -- uninstall\n/);
    assert.equal(result.stderr, '');
    assert.deepEqual(result.leftovers, []);
  }));

test('picks the arm64 tar.gz on aarch64 and reads a minified feed', { timeout: 30000 }, () =>
  withFixture({ minified: true }, async (root) => {
    const result = await run(root, [], { FAKE_UNAME_M: 'aarch64' });
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.downloads, [feedURL, releaseURL(`lithe-${version}-linux-arm64.tar.gz`)]);
  }));

test('runs from a pipe and warns when the prefix is outside the menu directories', { timeout: 30000 }, () =>
  withFixture({}, async (root) => {
    const prefix = path.join(root, 'opt');
    const result = await run(root, ['--prefix', prefix], {}, { pipe: true });
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.installArgs, ['install', '--prefix', prefix]);
    assert.match(result.stderr, /does not read .*\/opt\/share\/applications, so Lithe is not in the application menu/);
    assert.match(result.stdout, new RegExp(`uninstall --prefix ${prefix}\\n`));
  }));

test('a prefix listed in XDG_DATA_DIRS gets no menu warning', { timeout: 30000 }, () =>
  withFixture({}, async (root) => {
    const prefix = path.join(root, 'opt');
    const result = await run(root, [`--prefix=${prefix}/`], { XDG_DATA_DIRS: `/usr/share:${prefix}/share` });
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.installArgs, ['install', '--prefix', prefix]);
    assert.equal(result.stderr, '');
  }));

test('warns when another lithe comes first in PATH', { timeout: 30000 }, () =>
  withFixture({}, async (root) => {
    const other = path.join(root, 'other');
    await mkdir(other);
    await writeFile(path.join(other, 'lithe'), '#!/bin/sh\n', { mode: 0o755 });
    const result = await run(root, [], { PATH: `${path.join(root, 'bin')}:${other}:/usr/bin:/bin:/usr/sbin:/sbin` });
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stderr, new RegExp(`${other}/lithe comes before ${result.home}/\\.local/bin/lithe in PATH`));
  }));

test('stops without installing when the checksum differs from the feed', { timeout: 30000 }, () =>
  withFixture({ corrupt: true }, async (root) => {
    const result = await run(root);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /SHA-256 is [0-9a-f]{64}, but the update feed says [0-9a-f]{64}; nothing was installed/);
    assert.deepEqual(result.installArgs, []);
    assert.deepEqual(result.leftovers, []);
  }));

test('refuses before downloading anything', { timeout: 60000 }, async (t) => {
  const cases = [
    ['root', [], { FAKE_UID: '0' }, /run this as your own user, without sudo/],
    ['a DEB install', [], { FAKE_DPKG: 'installed' }, /Remove it with "sudo apt remove lithe"/],
    ['an RPM install', [], { FAKE_RPM: 'installed' }, /Remove it with "sudo dnf remove lithe"/],
    ['another architecture', [], { FAKE_UNAME_M: 'riscv64' }, /no Lithe build for riscv64/],
    ['another system', [], { FAKE_UNAME_S: 'Darwin' }, /this installer is for Linux/],
    ['a relative prefix', ['--prefix', 'opt'], {}, /must be an absolute path/],
    ['a prefix with a space', ['--prefix', '/opt/my apps'], {}, /may only contain letters/],
    ['an unknown option', ['--channel', 'beta'], {}, /^usage: linux\.sh/],
  ];
  for (const [name, args, env, message] of cases) {
    await t.test(name, () => withFixture({}, async (root) => {
      const result = await run(root, args, env);
      assert.notEqual(result.code, 0);
      assert.match(result.stderr, message);
      assert.deepEqual(result.downloads, []);
      assert.deepEqual(result.installArgs, []);
    }));
  }
});

test('names the zypper command for an RPM install on openSUSE', { timeout: 30000 }, () =>
  withFixture({ osRelease: 'ID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n' }, async (root) => {
    const result = await run(root, [], { FAKE_RPM: 'installed' });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /Remove it with "sudo zypper remove lithe"/);
  }));

test('uninstall runs the archive installer even next to a DEB install', { timeout: 30000 }, () =>
  withFixture({}, async (root) => {
    const result = await run(root, ['uninstall'], { FAKE_DPKG: 'installed' });
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.installArgs, ['uninstall', '--prefix', `${result.home}/.local`]);
    assert.match(result.stdout, /settings and projects are kept/);
  }));

test('names the packages for missing libraries but still installs', { timeout: 60000 }, async (t) => {
  const without = (...names) => allLibraries.filter((name) => !names.includes(name));
  const cases = [
    ['Ubuntu', 'ID=ubuntu\nID_LIKE=debian\n', /sudo apt install libglib2\.0-0 libxcb-cursor0$/m],
    ['Fedora', 'ID=fedora\n', /sudo dnf install 'libgobject-2\.0\.so\.0\(\)\(64bit\)' 'libxcb-cursor\.so\.0\(\)\(64bit\)'$/m],
    ['an unknown distribution', 'ID=nixos\n', /install the packages that provide libgobject-2\.0\.so\.0 libxcb-cursor\.so\.0$/m],
  ];
  for (const [name, osRelease, command] of cases) {
    await t.test(name, () => withFixture({ osRelease, libraries: without('libxcb-cursor.so.0', 'libgobject-2.0.so.0') },
      async (root) => {
        const result = await run(root);
        assert.equal(result.code, 0, result.stderr);
        assert.deepEqual(result.installArgs.slice(0, 1), ['install']);
        assert.match(result.stderr, /needs libraries this system lacks: libgobject-2\.0\.so\.0 libxcb-cursor\.so\.0$/m);
        assert.match(result.stderr, command);
        assert.doesNotMatch(result.stderr, /libvulkan/);
      }));
  }
  await t.test('only Vulkan', () => withFixture({ libraries: without('libvulkan.so.1') }, async (root) => {
    const result = await run(root);
    assert.equal(result.code, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /needs libraries/);
    assert.match(result.stderr, /draws on the CPU/);
    assert.match(result.stderr, /sudo apt install libvulkan1/);
  }));
});

test('refuses a feed it cannot use', { timeout: 60000 }, async (t) => {
  const cases = [
    ['another app', (feed) => ({ ...feed, app: 'app.example.other' }), /not Lithe's/],
    ['another schema', (feed) => ({ ...feed, schema: 2 }), /format this installer does not know/],
    ['no Linux amd64 archive', (feed) => ({ ...feed, latest: { ...feed.latest,
      assets: feed.latest.assets.filter((entry) => entry.arch !== 'amd64' || entry.os !== 'linux') } }),
    /no tar\.gz for Linux amd64/],
  ];
  for (const [name, feed, message] of cases) {
    await t.test(name, () => withFixture({ feed }, async (root) => {
      const result = await run(root);
      assert.equal(result.code, 1);
      assert.match(result.stderr, message);
      assert.deepEqual(result.downloads, [feedURL]);
      assert.deepEqual(result.leftovers, []);
    }));
  }
});

// The installer repeats facts the release owns; these fail when one side moves without the other.
test('matches the feed address, feed identity and DEB dependencies of the desktop build', async () => {
  const installer = await readFile(script, 'utf8');
  const buildinfo = await readFile(path.join(repository, 'desktop/internal/buildinfo/update.go'), 'utf8');
  const manifest = await readFile(path.join(repository, 'desktop/viva.toml'), 'utf8');
  assert.equal(buildinfo.match(/StableFeedURL\s*=\s*"([^"]+)"/)?.[1], feedURL);
  assert.ok(installer.includes(`\nfeed_url=${feedURL}\n`));
  const appID = buildinfo.match(/UpdateApp\s*=\s*"([^"]+)"/)?.[1];
  assert.ok(installer.includes(`\napp_id=${appID}\n`), `app_id should be ${appID}`);
  const depends = manifest.match(/^\[linux\][\s\S]*?^depends = \[([\s\S]*?)\]/m)?.[1].match(/"([^"]+)"/g)
    .map((name) => name.slice(1, -1));
  assert.ok(depends?.length > 0, 'desktop/viva.toml has [linux] depends');
  const required = installer.match(/required_libraries="([^"]+)"/)[1].split(/\s+/).map((entry) => entry.split('=')[1]);
  for (const name of depends) assert.ok(required.includes(name), `${name} from desktop/viva.toml is checked`);
});
