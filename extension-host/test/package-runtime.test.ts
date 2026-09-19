import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import * as fs from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import { verifiedArchive } from '../scripts/package-runtime';

const bytes = 'fixture archive';
const artifact = { url: 'https://example.invalid/runtime.tar.gz', sha256: createHash('sha256').update(bytes).digest('hex') };

test('runtime cache verifies every hit and replaces corrupted bytes', async () => {
    const cache = await fs.mkdtemp(path.join(os.tmpdir(), 'lithe-runtime-cache-'));
    try {
        let downloads = 0;
        const download = async (_: string, file: string) => {
            expect(path.isAbsolute(file)).toBe(true);
            downloads++;
            await fs.writeFile(file, bytes);
        };
        const archive = await verifiedArchive(artifact, path.relative(process.cwd(), cache), download);
        expect(downloads).toBe(1);
        expect(await verifiedArchive(artifact, cache, download)).toBe(archive);
        expect(downloads).toBe(1);
        await fs.writeFile(archive, 'corrupted');
        await verifiedArchive(artifact, cache, download);
        expect(downloads).toBe(2);
        expect(await fs.readFile(archive, 'utf8')).toBe(bytes);
        expect(await fs.readdir(cache)).toEqual([artifact.sha256]);
    } finally { await fs.rm(cache, { recursive: true, force: true }); }
});

test('runtime download mismatch is rejected and temporary bytes are removed', async () => {
    const cache = await fs.mkdtemp(path.join(os.tmpdir(), 'lithe-runtime-cache-'));
    try {
        await expect(verifiedArchive(artifact, cache, async (_, file) => {
            await fs.writeFile(file, 'wrong archive');
        })).rejects.toThrow('Checksum mismatch');
        expect(await fs.readdir(cache)).toEqual([]);
    } finally { await fs.rm(cache, { recursive: true, force: true }); }
});
