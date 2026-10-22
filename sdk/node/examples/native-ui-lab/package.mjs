// Development ZIP for the macOS DEBUG host. No npm install or network access.
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('.', import.meta.url));
const output = resolve(process.argv[2] ?? '.artifacts/native-ui-lab');
const plugin = join(output, 'NativeUILab');
await mkdir(plugin, { recursive: true });
for (const name of ['plugin.json', 'README.md', 'backend']) {
  await cp(join(source, name), join(plugin, name), { recursive: true });
}
await cp(new URL('../../src/', import.meta.url), join(plugin, 'backend/vendor/lithe-plugin-sdk/src'), { recursive: true });
const entry = join(plugin, 'backend/main.mjs');
await writeFile(entry, (await readFile(entry, 'utf8')).replace('../../../src/index.mjs', './vendor/lithe-plugin-sdk/src/index.mjs'));
const workspace = join(output, 'UI-Lab-Workspace');
await mkdir(workspace, { recursive: true });
await writeFile(join(workspace, 'lithe-ui-lab.json'), '{}\n');
await cp(join(source, 'README.md'), join(workspace, 'README.md'));
// A fresh archive avoids retaining deleted entries from an older build.
const manifest = JSON.parse(await readFile(join(plugin, 'plugin.json'), 'utf8'));
const zip = join(output, `NativeUILab-${manifest.version}.zip`);
await rm(zip, { force: true });
execFileSync('/usr/bin/zip', ['-qr', zip, 'NativeUILab'], { cwd: output });
console.log(`Plugin: ${zip}\nWorkspace: ${workspace}`);
