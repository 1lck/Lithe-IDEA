import * as fs from 'fs/promises';
import * as path from 'path';
import { StorageMain } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { KeysToAnyValues, KeysToKeysToAnyValue } from '@theia/plugin-ext/lib/common/types';

const STATE_FILE = 'extension-state.json';

/**
 * `ExtensionContext.globalState` / `workspaceState` persistence.
 *
 * This is extension-private state, not Lithe document or project state, so the
 * host owns it directly in the storage directories Lithe assigned at initialize.
 * Writes are serialized per scope and replace the file atomically.
 */
export class StateStore {
    private readonly state: Record<'global' | 'workspace', KeysToKeysToAnyValue> = { global: {}, workspace: {} };
    private readonly writes: Record<'global' | 'workspace', Promise<void>> = { global: Promise.resolve(), workspace: Promise.resolve() };

    constructor(private readonly directories: Record<'global' | 'workspace', string>) { }

    async load(): Promise<void> {
        for (const scope of ['global', 'workspace'] as const) {
            this.state[scope] = await readState(path.join(this.directories[scope], STATE_FILE));
        }
    }

    snapshot(scope: 'global' | 'workspace'): KeysToKeysToAnyValue {
        return structuredClone(this.state[scope]);
    }

    get(scope: 'global' | 'workspace', key: string): KeysToAnyValues {
        return structuredClone(this.state[scope][key] ?? {});
    }

    set(scope: 'global' | 'workspace', key: string, value: KeysToAnyValues): Promise<void> {
        this.state[scope][key] = structuredClone(value);
        const contents = JSON.stringify(this.state[scope], undefined, 2);
        const directory = this.directories[scope];
        this.writes[scope] = this.writes[scope].then(() => writeAtomically(directory, contents));
        return this.writes[scope];
    }

    /** Resolves once every queued write has reached disk (or failed). */
    async flush(): Promise<void> {
        await Promise.allSettled([this.writes.global, this.writes.workspace]);
    }
}

export class LitheStorageMain implements StorageMain {
    constructor(private readonly store: StateStore) { }

    async $set(key: string, value: KeysToAnyValues, isGlobal: boolean): Promise<boolean> {
        await this.store.set(isGlobal ? 'global' : 'workspace', key, value);
        return true;
    }

    async $get(key: string, isGlobal: boolean): Promise<KeysToAnyValues> {
        return this.store.get(isGlobal ? 'global' : 'workspace', key);
    }

    async $getAll(isGlobal: boolean): Promise<KeysToKeysToAnyValue> {
        return this.store.snapshot(isGlobal ? 'global' : 'workspace');
    }
}

async function readState(file: string): Promise<KeysToKeysToAnyValue> {
    let contents: string;
    try {
        contents = await fs.readFile(file, 'utf8');
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
            return {};
        }
        throw error;
    }
    const parsed: unknown = JSON.parse(contents);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        throw new Error(`${file} does not contain a JSON object.`);
    }
    return parsed as KeysToKeysToAnyValue;
}

async function writeAtomically(directory: string, contents: string): Promise<void> {
    await fs.mkdir(directory, { recursive: true });
    const target = path.join(directory, STATE_FILE);
    const temporary = `${target}.${process.pid}.tmp`;
    await fs.writeFile(temporary, contents, 'utf8');
    await fs.rename(temporary, target);
}
