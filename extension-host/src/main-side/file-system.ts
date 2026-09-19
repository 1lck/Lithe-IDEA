import * as fs from 'fs/promises';
import { BinaryBuffer } from '@theia/core/lib/common/buffer';
import { FileSystemMain } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { UriComponents } from '@theia/plugin-ext/lib/common/uri-components';
import { FileType, FileSystemProviderErrorCode, Stat } from '@theia/filesystem/lib/common/files';
import { URI } from '@theia/core/shared/vscode-uri';

/**
 * `vscode.workspace.fs` for the `file` scheme.
 *
 * Extensions already run with full Node filesystem access in this process, so
 * routing `workspace.fs` through Lithe would add a hop without adding a
 * permission boundary. Writes go straight to disk exactly like VS Code's disk
 * provider; Lithe learns about them from its own file watchers, which keeps
 * Lithe's open documents authoritative for unsaved content.
 */
export class LitheFileSystemMain implements Partial<FileSystemMain> {
    async $stat(uri: UriComponents): Promise<Stat> {
        return translateErrors(async () => {
            const target = toPath(uri);
            const linkStat = await fs.lstat(target);
            const stat = linkStat.isSymbolicLink() ? await fs.stat(target) : linkStat;
            let type = stat.isDirectory() ? FileType.Directory : stat.isFile() ? FileType.File : FileType.Unknown;
            if (linkStat.isSymbolicLink()) {
                type |= FileType.SymbolicLink;
            }
            return { type, ctime: stat.birthtimeMs, mtime: stat.mtimeMs, size: stat.size };
        });
    }

    async $readdir(uri: UriComponents): Promise<[string, FileType][]> {
        return translateErrors(async () => {
            const entries = await fs.readdir(toPath(uri), { withFileTypes: true });
            return entries
                .map((entry): [string, FileType] => [entry.name,
                    entry.isDirectory() ? FileType.Directory : entry.isFile() ? FileType.File
                        : entry.isSymbolicLink() ? FileType.SymbolicLink : FileType.Unknown])
                .sort(([left], [right]) => left.localeCompare(right));
        });
    }

    async $readFile(uri: UriComponents): Promise<BinaryBuffer> {
        return translateErrors(async () => BinaryBuffer.wrap(new Uint8Array(await fs.readFile(toPath(uri)))));
    }

    async $writeFile(uri: UriComponents, content: BinaryBuffer): Promise<void> {
        return translateErrors(() => fs.writeFile(toPath(uri), content.buffer));
    }

    async $mkdir(uri: UriComponents): Promise<void> {
        return translateErrors(async () => {
            await fs.mkdir(toPath(uri));
        });
    }

    async $delete(uri: UriComponents, options: { recursive: boolean; useTrash: boolean }): Promise<void> {
        // `useTrash` needs the platform recycle bin, which only Lithe can reach; refuse instead of deleting permanently.
        if (options.useTrash) {
            throw providerError('Deleting to the trash is not supported by the Lithe extension host.', FileSystemProviderErrorCode.Unavailable);
        }
        return translateErrors(() => fs.rm(toPath(uri), { recursive: options.recursive }));
    }

    async $rename(source: UriComponents, target: UriComponents, options: { overwrite: boolean }): Promise<void> {
        return translateErrors(async () => {
            await refuseExistingTarget(target, options.overwrite);
            await fs.rename(toPath(source), toPath(target));
        });
    }

    async $copy(source: UriComponents, target: UriComponents, options: { overwrite: boolean }): Promise<void> {
        return translateErrors(async () => {
            await refuseExistingTarget(target, options.overwrite);
            await fs.cp(toPath(source), toPath(target), { recursive: true, force: options.overwrite, errorOnExist: !options.overwrite });
        });
    }
}

function toPath(components: UriComponents): string {
    const uri = URI.from(components);
    if (uri.scheme !== 'file') {
        // Theia maps `ENOPRO` to FileSystemError.Unavailable on the extension side.
        const error = new Error(`No file system provider for scheme ${uri.scheme}.`);
        error.name = 'ENOPRO';
        throw error;
    }
    return uri.fsPath;
}

async function refuseExistingTarget(target: UriComponents, overwrite: boolean): Promise<void> {
    if (overwrite) {
        return;
    }
    const exists = await fs.access(toPath(target)).then(() => true, () => false);
    if (exists) {
        throw providerError(`${URI.from(target).toString()} already exists.`, FileSystemProviderErrorCode.FileExists);
    }
}

/** Theia's extension side maps these error names to the matching `vscode.FileSystemError`. */
function providerError(message: string, code: FileSystemProviderErrorCode): Error {
    const error = new Error(message);
    error.name = code;
    return error;
}

async function translateErrors<T>(operation: () => Promise<T>): Promise<T> {
    try {
        return await operation();
    } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        const message = error instanceof Error ? error.message : String(error);
        switch (code) {
            case 'ENOENT': throw providerError(message, FileSystemProviderErrorCode.FileNotFound);
            case 'EEXIST': case 'ERR_FS_CP_EEXIST': throw providerError(message, FileSystemProviderErrorCode.FileExists);
            case 'ENOTDIR': throw providerError(message, FileSystemProviderErrorCode.FileNotADirectory);
            case 'EISDIR': throw providerError(message, FileSystemProviderErrorCode.FileIsADirectory);
            case 'EACCES': case 'EPERM': throw providerError(message, FileSystemProviderErrorCode.NoPermissions);
            default: throw error;
        }
    }
}
