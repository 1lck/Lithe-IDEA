// Builds a relocatable macOS preview resource directory, never from local node_modules.
// Upstream Node/VSIX bytes are pinned in runtime-lock.json; npm bytes in bun.lock.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';

interface Artifact { url: string; sha256: string }
interface Extension extends Artifact { id: string; version: string; source: string; license: string }
interface RuntimeLock {
    schemaVersion: number;
    node: { version: string; platforms: Record<string, Artifact> };
    extensions: Extension[];
}

const hostRoot = path.resolve(import.meta.dir, '..');
const repository = path.resolve(hostRoot, '..');

function run(command: string, args: string[], cwd: string, timeout = 300_000): void {
    const result = spawnSync(command, args, { cwd, timeout, killSignal: 'SIGKILL', stdio: ['ignore', 'inherit', 'inherit'] });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal})`);
}

export async function sha256(file: string): Promise<string> {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(file)) hash.update(chunk);
    return hash.digest('hex');
}

/** Every cache hit is checked again; a partial or replaced archive cannot be extracted. */
export async function verifiedArchive(
    artifact: Artifact, cache: string,
    download: (url: string, file: string) => Promise<void> = async (url, file) => {
        run('curl', ['--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
            '--connect-timeout', '15', '--max-time', '600', '--retry', '1', '--retry-max-time', '600',
            '--silent', '--show-error', '--output', file, url], path.dirname(file), 1_250_000);
    }
): Promise<string> {
    cache = path.resolve(cache);
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256)) throw new Error('Invalid artifact checksum');
    const url = new URL(artifact.url);
    if (url.protocol !== 'https:') throw new Error('Artifact downloads require HTTPS');
    await fs.mkdir(cache, { recursive: true });
    const destination = path.join(cache, artifact.sha256);
    try {
        const stat = await fs.lstat(destination);
        if (stat.isFile() && await sha256(destination) === artifact.sha256) return destination;
        await fs.rm(destination, { recursive: true, force: true });
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    }
    const temporary = await fs.mkdtemp(path.join(cache, '.download-'));
    try {
        const file = path.join(temporary, 'archive');
        await download(url.href, file);
        if (await sha256(file) !== artifact.sha256) throw new Error(`Checksum mismatch: ${url.href}`);
        await fs.rename(file, destination);
        return destination;
    } finally {
        await fs.rm(temporary, { recursive: true, force: true });
    }
}

export function selectPlatforms(requested: string, lock: RuntimeLock): string[] {
    const platforms = [...new Set(requested.split(','))].sort();
    if (platforms.length === 0 || platforms.some(platform => !Object.hasOwn(lock.node.platforms, platform))) {
        throw new Error(`Unsupported runtime platforms: ${requested}`);
    }
    return platforms;
}

async function packageRuntime(platforms: string[], output: string, cache: string, lock: RuntimeLock): Promise<void> {
    // Refuse overwrites: failed preparation must never damage the previous artifact.
    try {
        await fs.lstat(output);
        throw new Error(`Output already exists; select a new staging directory: ${output}`);
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    }
    await fs.mkdir(path.dirname(output), { recursive: true });
    const stage = await fs.mkdtemp(path.join(path.dirname(output), '.extension-host-'));
    try {
        const nodePaths: Record<string, string> = {};
        for (const platform of platforms) {
            const archive = await verifiedArchive(lock.node.platforms[platform], cache);
            const runtime = path.join(stage, 'runtimes', platform);
            await fs.mkdir(runtime, { recursive: true });
            const prefix = `node-v${lock.node.version}-${platform}`;
            // Node itself and its complete third-party license are sufficient at runtime.
            run('tar', ['-xzf', archive, '-C', runtime, '--strip-components=1', `${prefix}/bin/node`, `${prefix}/LICENSE`], stage);
            const architecture = platform === 'darwin-arm64' ? 'arm64' : 'x86_64';
            run('lipo', [path.join(runtime, 'bin/node'), '-verify_arch', architecture], stage);
            nodePaths[platform] = `runtimes/${platform}/bin/node`;
        }
        const extensionPaths: string[] = [];
        for (const extension of lock.extensions) {
            const archive = await verifiedArchive(extension, cache);
            const unpack = path.join(stage, '.vsix');
            await fs.mkdir(unpack);
            run('unzip', ['-q', archive, 'extension/*', '-d', unpack], stage);
            const contents = path.join(unpack, 'extension');
            const manifest = JSON.parse(await fs.readFile(path.join(contents, 'package.json'), 'utf8'));
            if (`${manifest.publisher}.${manifest.name}` !== extension.id || manifest.version !== extension.version) {
                throw new Error(`VSIX identity mismatch: ${extension.id}`);
            }
            await fs.access(path.join(contents, 'LICENSE.txt'));
            const relative = `extensions/${extension.id}`;
            await fs.mkdir(path.join(stage, 'extensions'), { recursive: true });
            await fs.rename(contents, path.join(stage, relative));
            await fs.rm(unpack, { recursive: true });
            extensionPaths.push(relative);
        }
        const host = path.join(stage, 'host');
        await fs.mkdir(host);
        for (const file of ['package.json', 'bun.lock']) await fs.copyFile(path.join(hostRoot, file), path.join(host, file));
        // Optional binaries for both macOS architectures; no machine-specific build scripts.
        // The selected plugin-side subsystem does not use Theia's native backend modules.
        run('bun', ['install', '--frozen-lockfile', '--production', '--ignore-scripts', '--linker=hoisted', '--os=darwin', '--cpu=*'], host);
        run('bun', ['build', 'src/main.ts', '--target=node', '--format=cjs', '--packages=external',
            `--outfile=${path.join(host, 'dist/main.js')}`], hostRoot);
        await fs.copyFile(path.join(repository, 'LICENSE'), path.join(host, 'LICENSE'));
        await fs.copyFile(path.join(hostRoot, 'runtime-lock.json'), path.join(stage, 'runtime-lock.json'));
        await fs.writeFile(path.join(stage, 'NOTICE.txt'),
            'Lithe VS Code extension host preview\n\n' +
            'Node.js: https://nodejs.org/ (licenses in runtimes/<platform>/LICENSE)\n' +
            'Theia 1.75.0 (EPL-2.0) source: https://github.com/eclipse-theia/theia/tree/v1.75.0\n' +
            'Theia and npm dependencies: original licenses in host/node_modules; versions in host/bun.lock.\n' +
            lock.extensions.map(extension => `${extension.id} ${extension.version} (${extension.license})\n` +
                `Source: ${extension.source}\nOriginal license and notices: extensions/${extension.id}/\n`).join('\n'));
        await fs.writeFile(path.join(stage, 'manifest.json'), JSON.stringify({
            schemaVersion: 1, nodePaths, entrypoint: 'host/dist/main.js', extensionPaths: extensionPaths.sort()
        }, null, 2) + '\n');
        await fs.rename(stage, output);
    } finally {
        await fs.rm(stage, { recursive: true, force: true });
    }
}

if (import.meta.main) {
    try {
        const [platforms, output, cache = path.join(repository, '.artifacts/extension-host-downloads')] = process.argv.slice(2);
        if (!platforms || !output || process.argv.length > 5) {
            throw new Error('Usage: bun scripts/package-runtime.ts darwin-arm64[,darwin-x64] <new-output-directory> [cache-directory]');
        }
        if (process.platform !== 'darwin') throw new Error('macOS runtime packaging requires macOS (architecture validation and signing).');
        const lock: RuntimeLock = JSON.parse(await fs.readFile(path.join(hostRoot, 'runtime-lock.json'), 'utf8'));
        if (lock.schemaVersion !== 1) throw new Error('Unsupported runtime lock schema');
        await packageRuntime(selectPlatforms(platforms, lock), path.resolve(output), path.resolve(cache), lock);
        process.stdout.write(`Prepared extension host resources: ${path.resolve(output)}\n`);
    } catch (error) {
        process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
        process.exitCode = 1;
    }
}
