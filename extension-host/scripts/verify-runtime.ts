// A real packaged Node launches the relocated host with production-only dependencies.
// Loading official Java extensions is checked without activating a workspace/JDT LS.
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';
import { FakeLithe } from '../test/support/fake-lithe';

const [directory, requestedPlatforms, mode] = process.argv.slice(2);
if (!directory || !requestedPlatforms || (mode && mode !== '--layout-only')) {
    throw new Error('Usage: bun scripts/verify-runtime.ts <resource-root> darwin-arm64[,darwin-x64] [--layout-only]');
}
const root = await fs.realpath(directory);
const manifest = JSON.parse(await fs.readFile(path.join(root, 'manifest.json'), 'utf8'));
const lock = JSON.parse(await fs.readFile(path.resolve(import.meta.dir, '../runtime-lock.json'), 'utf8'));
async function resource(relative: string): Promise<string> {
    if (typeof relative !== 'string' || relative.includes('\\') ||
        relative.split('/').some(part => !part || part === '..' || part === '.')) {
        throw new Error('Invalid relative runtime resource path');
    }
    const result = await fs.realpath(path.join(root, relative));
    if (!result.startsWith(root + path.sep)) throw new Error('Runtime resource escapes its root');
    return result;
}
if (manifest.schemaVersion !== 1) throw new Error('Invalid runtime manifest schema');
const entrypoint = await resource(manifest.entrypoint);
const extensionPaths: string[] = [];
if (manifest.extensionPaths.length !== lock.extensions.length) throw new Error('Unexpected extension set');
for (const extension of lock.extensions) {
    const relative = `extensions/${extension.id}`;
    if (!manifest.extensionPaths.includes(relative)) throw new Error(`Missing extension: ${extension.id}`);
    const extensionRoot = await resource(relative);
    const actual = JSON.parse(await fs.readFile(path.join(extensionRoot, 'package.json'), 'utf8'));
    if (`${actual.publisher}.${actual.name}` !== extension.id || actual.version !== extension.version) {
        throw new Error(`Unexpected extension version: ${extension.id}`);
    }
    await resource(`${relative}/LICENSE.txt`);
    extensionPaths.push(extensionRoot);
}
for (const platform of requestedPlatforms.split(',')) {
    if (!Object.hasOwn(lock.node.platforms, platform)) throw new Error(`Unsupported platform: ${platform}`);
    const node = await resource(manifest.nodePaths[platform]);
    const result = spawnSync('lipo', [node, '-verify_arch', platform === 'darwin-arm64' ? 'arm64' : 'x86_64'],
        { timeout: 10_000, killSignal: 'SIGKILL', encoding: 'utf8' });
    if (result.error || result.status !== 0) throw new Error(`Incorrect Node architecture: ${platform}`);
    await resource(`runtimes/${platform}/LICENSE`);
    if (mode === '--layout-only') continue;
    // Rosetta's first translation of a new Node binary can exceed ten seconds.
    const version = spawnSync(node, ['--version'], { timeout: 60_000, killSignal: 'SIGKILL', encoding: 'utf8' });
    if (version.error || version.status !== 0 || version.stdout.trim() !== `v${lock.node.version}`) {
        throw new Error(`Cannot execute pinned Node for ${platform}: ${version.error ?? version.stderr}`);
    }
    const lithe = FakeLithe.launch(undefined, { node, entrypoint });
    try {
        const result = await lithe.request('host/initialize', lithe.initializeParams({
            extensionPaths, workspaceTrusted: false
        }));
        if (result.protocolVersion !== 1 || result.failedExtensions?.length !== 0) {
            throw new Error(`Packaged extension loading failed: ${JSON.stringify(result)}\n${lithe.stderr}`);
        }
        const loaded = result.extensions.map((extension: { id: string }) => extension.id).sort();
        const expected = lock.extensions.map((extension: { id: string }) => extension.id).sort();
        if (JSON.stringify(loaded) !== JSON.stringify(expected)) throw new Error('Packaged host did not load the pinned extension set');
        await lithe.request('host/shutdown', { timeoutMilliseconds: 1000 });
        if (await lithe.waitForExit() !== 0) throw new Error('Packaged host shutdown failed');
        process.stdout.write(`${platform}: packaged Node ${version.stdout.trim()}, official extensions loaded\n`);
    } finally { await lithe.dispose(); }
}
