import { RPCProtocol } from '@theia/plugin-ext/lib/common/rpc-protocol';
import { MAIN_RPC_CONTEXT, PLUGIN_RPC_CONTEXT } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { LitheConnection } from '../lithe-connection';
import { Methods, ProtocolFailure } from '../protocol';
import { LitheCommandRegistryMain } from './commands';
import { DocumentMirror, LitheDocumentsMain, LitheTextEditorsMain } from './documents';
import { LitheEnvMain, LitheLoggerMain, LitheMessageRegistryMain, LitheNotificationMain, LitheWorkspaceMain } from './window';
import { LitheStorageMain, StateStore } from './storage';
import { LitheFileSystemMain } from './file-system';

/** Shared services for every Lithe `*Main` implementation. */
export class MainContext {
    private readonly reportedUnsupported = new Set<string>();

    constructor(
        readonly connection: LitheConnection,
        private readonly diagnostics: (message: string) => void
    ) { }

    /**
     * Returns the error for an API Lithe does not implement yet and reports the API
     * to Lithe once. The compatibility matrix for each extension is built from these
     * reports, so an unimplemented call must never be answered with a fake success.
     */
    unsupported(api: string): Error {
        if (!this.reportedUnsupported.has(api)) {
            this.reportedUnsupported.add(api);
            this.connection.notify(Methods.unsupportedApi, { api });
        }
        return new ProtocolFailure('unsupportedApi', `Lithe does not support ${api} yet.`, { api });
    }

    unsupportedApis(): string[] {
        return [...this.reportedUnsupported].sort();
    }

    /** Observes a main -> plugin call whose result nobody awaits, so failures are logged instead of lost. */
    forward(call: PromiseLike<unknown> | unknown): void {
        if (call && typeof (call as PromiseLike<unknown>).then === 'function') {
            (call as PromiseLike<unknown>).then(undefined, error => {
                this.diagnostics(`Plugin side rejected a forwarded call: ${error instanceof Error ? error.message : String(error)}`);
            });
        }
    }
}

export interface MainSide {
    context: MainContext;
    documents: DocumentMirror;
    commands: LitheCommandRegistryMain;
    workspace: LitheWorkspaceMain;
    storage: StateStore;
}

/**
 * Registers Lithe's implementation of every `*Main` interface on the main-side RPC.
 *
 * Interfaces and methods without a Lithe implementation are still registered, as
 * proxies that reject with `unsupportedApi`, so an extension gets an explicit error
 * instead of Theia's generic "no local service handler".
 */
export function registerMainSide(rpc: RPCProtocol, connection: LitheConnection, storage: StateStore,
    diagnostics: (message: string) => void): MainSide {
    const context = new MainContext(connection, diagnostics);
    const documents = new DocumentMirror(
        rpc.getProxy(MAIN_RPC_CONTEXT.EDITORS_AND_DOCUMENTS_EXT),
        rpc.getProxy(MAIN_RPC_CONTEXT.DOCUMENTS_EXT),
        context);
    const commands = new LitheCommandRegistryMain(context);
    const workspace = new LitheWorkspaceMain(context);
    const implementations: Partial<Record<keyof typeof PLUGIN_RPC_CONTEXT, object>> = {
        LOGGER_MAIN: new LitheLoggerMain(context),
        COMMAND_REGISTRY_MAIN: commands,
        DOCUMENTS_MAIN: new LitheDocumentsMain(context, documents),
        TEXT_EDITORS_MAIN: new LitheTextEditorsMain(context),
        MESSAGE_REGISTRY_MAIN: new LitheMessageRegistryMain(context),
        NOTIFICATION_MAIN: new LitheNotificationMain(context),
        ENV_MAIN: new LitheEnvMain(),
        STORAGE_MAIN: new LitheStorageMain(storage),
        WORKSPACE_MAIN: workspace,
        FILE_SYSTEM_MAIN: new LitheFileSystemMain(),
    };
    // Every PLUGIN_RPC_CONTEXT entry is served by the main side; `ProxyIdentifier.isMain`
    // does not encode direction in Theia 1.75.0, so the table itself is the source.
    for (const key of Object.keys(PLUGIN_RPC_CONTEXT) as (keyof typeof PLUGIN_RPC_CONTEXT)[]) {
        rpc.set(PLUGIN_RPC_CONTEXT[key], withUnsupportedFallback(interfaceName(key), implementations[key] ?? {}, context));
    }
    return { context, documents, commands, workspace, storage };
}

function withUnsupportedFallback(name: string, implementation: object, context: MainContext): object {
    return new Proxy(implementation, {
        get(target, property, receiver) {
            if (typeof property !== 'string' || !property.startsWith('$') || property in target) {
                return Reflect.get(target, property, receiver);
            }
            return () => Promise.reject(context.unsupported(`${name}.${property}`));
        },
    });
}

/** `TEXT_EDITORS_MAIN` -> `TextEditorsMain`, matching the interface names in plugin-api-rpc. */
function interfaceName(key: string): string {
    return key.toLowerCase().split('_').map(part => part.charAt(0).toUpperCase() + part.slice(1)).join('');
}
