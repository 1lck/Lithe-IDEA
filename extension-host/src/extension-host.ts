import * as path from 'path';
import { RPCProtocol, RPCProtocolImpl } from '@theia/plugin-ext/lib/common/rpc-protocol';
import { ExtensionKind, MAIN_RPC_CONTEXT, PluginManagerExt, CommandRegistryExt, UIKind } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { VSCODE_DEFAULT_API_VERSION } from '@theia/plugin-ext-vscode/lib/common/plugin-vscode-types';
import { LitheConnection } from './lithe-connection';
import {
    DocumentChangedParams, DocumentSnapshot, InitializeParams, InitializeResult, isRecord, Methods,
    PROTOCOL_VERSION, ProtocolFailure
} from './protocol';
import { scanExtension, ScannedExtension } from './extension-scanner';
import { createInMemoryChannelPair } from './theia/in-memory-channel';
import { createPluginSide, PluginSide } from './theia/plugin-host-container';
import { MainSide, registerMainSide } from './main-side/main-context';
import { StateStore } from './main-side/storage';
import { fromProtocolValue, toProtocolValue } from './main-side/uri';
import { ChildProcessTracker } from './child-process-tracker';

/**
 * Activation event kinds Lithe can raise today. Extensions declaring other kinds
 * still load, and Theia logs the unsupported kinds, which feeds the per-extension
 * compatibility review.
 */
const SUPPORTED_ACTIVATION_EVENTS = ['*', 'onStartupFinished', 'onCommand', 'onLanguage', 'workspaceContains'];

const DEFAULT_SHUTDOWN_MILLISECONDS = 10_000;
/** Per-signal wait for leftover children: worst case adds twice this to the shutdown timeout. */
const CHILD_PROCESS_GRACE_MILLISECONDS = 3_000;

type HostState = 'created' | 'initializing' | 'ready' | 'shuttingDown' | 'stopped';

interface Running {
    pluginSide: PluginSide;
    mainRpc: RPCProtocol;
    mainSide: MainSide;
    manager: PluginManagerExt;
    commands: CommandRegistryExt;
}

/**
 * Owns one extension host session: a single initialize, any number of
 * activations and commands, and one bounded shutdown.
 *
 * The host never activates extensions on its own. Lithe raises every activation
 * event, including `*` and `onStartupFinished`, so safe mode, workspace trust and
 * disabled modules can keep extension code from running at all.
 */
export class ExtensionHost {
    private state: HostState = 'created';
    private running: Running | undefined;
    private shutdownPromise: Promise<void> | undefined;

    constructor(
        private readonly connection: LitheConnection,
        private readonly diagnostics: (message: string) => void,
        private readonly childProcesses: ChildProcessTracker,
        private readonly exit: (code: number) => void
    ) {
        connection.onRequest(Methods.initialize, params => this.initialize(params));
        connection.onRequest(Methods.activateByEvent, params => this.activateByEvent(params));
        connection.onRequest(Methods.executeExtensionCommand, params => this.executeCommand(params));
        connection.onRequest('host/resolveCompletion', (params, signal) => {
            if (!isRecord(params)) throw new ProtocolFailure('invalidParams', 'Completion resolution requires an object.');
            return this.ready().mainSide.languages.resolveCompletion(params, signal);
        });
        connection.onRequest('host/provideLanguageFeature', (params, signal) => this.provideLanguageFeature(params, signal));
        connection.onRequest(Methods.shutdown, params => this.shutdown(params));
        connection.onNotification(Methods.documentOpened, params => this.ready().mainSide.documents.open(params as DocumentSnapshot));
        connection.onNotification(Methods.documentChanged, params => {
            const side = this.ready().mainSide;
            side.documents.change(params as DocumentChangedParams);
            side.languages.releaseDocument(requireString(params, 'uri'));
        });
        connection.onNotification(Methods.documentSaved, params => this.ready().mainSide.documents.saved(requireString(params, 'uri')));
        connection.onNotification(Methods.documentClosed, params => {
            const side = this.ready().mainSide;
            const uri = requireString(params, 'uri');
            side.documents.close(uri);
            side.languages.releaseDocument(uri);
        });
        // Lithe closed stdin: it is gone or wants the host gone. Nobody is left to answer.
        connection.onClose(() => {
            void this.stop(DEFAULT_SHUTDOWN_MILLISECONDS).finally(() => this.exit(0));
        });
    }

    private async initialize(raw: unknown): Promise<InitializeResult> {
        if (this.state !== 'created') {
            throw new ProtocolFailure('alreadyInitialized', 'host/initialize may be sent only once per host process.');
        }
        const params = validateInitialize(raw);
        this.state = 'initializing';
        if (params.requestTimeoutMilliseconds !== undefined) {
            this.connection.requestTimeoutMilliseconds = params.requestTimeoutMilliseconds;
        }

        const storage = new StateStore({ global: params.storage.globalStoragePath, workspace: params.storage.workspaceStoragePath });
        await storage.load();

        const [mainChannel, pluginChannel] = createInMemoryChannelPair();
        const pluginSide = createPluginSide(pluginChannel);
        const mainRpc = new RPCProtocolImpl(mainChannel);
        const mainSide = registerMainSide(mainRpc, this.connection, storage, this.diagnostics);
        const manager = mainRpc.getProxy(MAIN_RPC_CONTEXT.HOSTED_PLUGIN_MANAGER_EXT);
        const commands = mainRpc.getProxy(MAIN_RPC_CONTEXT.COMMAND_REGISTRY_EXT);
        mainSide.commands.setLitheCommands(params.commands ?? []);
        mainSide.workspace.setTrusted(params.workspaceTrusted === true);
        this.running = { pluginSide, mainRpc, mainSide, manager, commands };

        const scanned: ScannedExtension[] = [];
        const failedExtensions: InitializeResult['failedExtensions'] = [];
        for (const extensionPath of [...params.extensionPaths].sort()) {
            try {
                scanned.push(await scanExtension(extensionPath));
            } catch (error) {
                failedExtensions.push({ path: extensionPath, message: error instanceof Error ? error.message : String(error) });
            }
        }
        scanned.sort((left, right) => left.summary.id.localeCompare(right.summary.id));
        await manager.$init({
            preferences: {
                // Sorted by extension id so conflicting contributed defaults resolve deterministically.
                0: Object.assign({}, ...scanned.map(extension => extension.configurationDefaults), params.configuration?.defaults ?? {}),
                1: params.configuration?.user ?? {},
                2: params.configuration?.workspace ?? {},
                3: {},
            },
            globalState: storage.snapshot('global'),
            workspaceState: storage.snapshot('workspace'),
            env: {
                queryParams: {},
                language: params.environment?.language ?? 'en',
                shell: params.environment?.shell ?? '',
                uiKind: UIKind.Desktop,
                appName: params.environment?.appName ?? 'Lithe',
                appHost: 'desktop',
                appRoot: path.dirname(__dirname),
                appUriScheme: 'lithe',
            },
            extApi: [],
            webview: { webviewResourceRoot: '', webviewCspSource: '' },
            jsonValidation: [],
            pluginKind: ExtensionKind.UI,
            supportedActivationEvents: SUPPORTED_ACTIVATION_EVENTS,
        });
        const workspaceExt = mainRpc.getProxy(MAIN_RPC_CONTEXT.WORKSPACE_EXT);
        workspaceExt.$onWorkspaceFoldersChanged({ roots: params.workspaceFolders.map(folder => folder.uri) });
        workspaceExt.$onWorkspaceTrustChanged(params.workspaceTrusted === true);

        await manager.$start({
            plugins: scanned.map(extension => extension.metadata),
            configStorage: {
                hostLogPath: params.storage.logPath,
                hostStoragePath: params.storage.workspaceStoragePath,
                hostGlobalStoragePath: params.storage.globalStoragePath,
            },
            activationEvents: [],
        });

        this.state = 'ready';
        return {
            protocolVersion: PROTOCOL_VERSION,
            apiVersion: VSCODE_DEFAULT_API_VERSION,
            extensions: scanned.map(extension => extension.summary),
            failedExtensions,
        };
    }

    private async activateByEvent(params: unknown): Promise<null> {
        const event = requireString(params, 'event');
        await this.ready().manager.$activateByEvent(event);
        return null;
    }

    private async provideLanguageFeature(params: unknown, signal: AbortSignal): Promise<unknown> {
        const value = this.ready();
        if (!isRecord(params) || typeof params.kind !== 'string' || typeof params.uri !== 'string') {
            throw new ProtocolFailure('invalidParams', 'host/provideLanguageFeature requires kind and uri.');
        }
        return toProtocolValue(await value.mainSide.languages.provide(params.kind, params, signal));
    }

    private async executeCommand(params: unknown): Promise<unknown> {
        const running = this.ready();
        const command = requireString(params, 'command');
        const args = isRecord(params) && Array.isArray(params.arguments) ? params.arguments : [];
        // Same as VS Code: executing a command first activates the extensions that contribute it.
        await running.manager.$activateByEvent(`onCommand:${command}`);
        if (!running.mainSide.commands.hasExtensionHandler(command)) {
            throw new ProtocolFailure('commandNotFound', `No extension registered command ${command}.`, { command });
        }
        try {
            const result = await running.commands.$executeCommand(command, ...args.map(fromProtocolValue));
            return toProtocolValue(result);
        } catch (error) {
            throw new ProtocolFailure('commandFailed', error instanceof Error ? error.message : String(error), { command });
        }
    }

    private async shutdown(params: unknown): Promise<null> {
        const timeout = isRecord(params) && typeof params.timeoutMilliseconds === 'number'
            ? params.timeoutMilliseconds : DEFAULT_SHUTDOWN_MILLISECONDS;
        await this.stop(timeout);
        // Reply first; the process exits after the response has been flushed.
        setImmediate(() => this.exit(0));
        return null;
    }

    /** Deactivates extensions within `timeoutMilliseconds`, then releases the RPC pair. Idempotent. */
    private stop(timeoutMilliseconds: number): Promise<void> {
        if (!this.shutdownPromise) {
            this.state = 'shuttingDown';
            this.shutdownPromise = (async () => {
                const running = this.running;
                if (running) {
                    let deadline: ReturnType<typeof setTimeout> | undefined;
                    const expired = new Promise<'expired'>(resolve => {
                        deadline = setTimeout(() => resolve('expired'), timeoutMilliseconds);
                    });
                    const outcome = await Promise.race([running.pluginSide.pluginHost.terminate().then(() => 'done' as const), expired]);
                    clearTimeout(deadline);
                    if (outcome === 'expired') {
                        this.diagnostics(`Extensions did not deactivate within ${timeoutMilliseconds} ms; stopping anyway.`);
                    }
                    await running.mainSide.storage.flush();
                    running.mainRpc.dispose();
                    running.pluginSide.rpc.dispose();
                }
                // Extensions had their chance to stop their processes in deactivate().
                const terminated = await this.childProcesses.terminateAll(CHILD_PROCESS_GRACE_MILLISECONDS);
                if (terminated > 0) {
                    const message = `Terminated ${terminated} child process(es) extensions left running at shutdown.`;
                    this.diagnostics(message);
                    this.connection.notify(Methods.log, { level: 'warning', source: 'host', message });
                }
                this.state = 'stopped';
            })();
        }
        return this.shutdownPromise;
    }

    private ready(): Running {
        if (this.state === 'shuttingDown' || this.state === 'stopped') {
            throw new ProtocolFailure('shuttingDown', 'The extension host is shutting down.');
        }
        if (this.state !== 'ready' || !this.running) {
            throw new ProtocolFailure('notInitialized', 'Send host/initialize and wait for its response first.');
        }
        return this.running;
    }
}

function requireString(params: unknown, field: string): string {
    if (!isRecord(params) || typeof params[field] !== 'string') {
        throw new ProtocolFailure('invalidParams', `Expected a string field "${field}".`, { field });
    }
    return params[field] as string;
}

function validateInitialize(raw: unknown): InitializeParams {
    if (!isRecord(raw)) {
        throw new ProtocolFailure('invalidParams', 'host/initialize params must be an object.');
    }
    if (raw.protocolVersion !== PROTOCOL_VERSION) {
        throw new ProtocolFailure('invalidParams', `Unsupported protocol version ${String(raw.protocolVersion)}; this host speaks ${PROTOCOL_VERSION}.`,
            { supportedVersion: PROTOCOL_VERSION });
    }
    const folders = raw.workspaceFolders;
    if (!Array.isArray(folders) || !folders.every(folder => isRecord(folder) && typeof folder.uri === 'string' && typeof folder.name === 'string')) {
        throw new ProtocolFailure('invalidParams', 'workspaceFolders must be a list of { uri, name }.');
    }
    const extensionPaths = raw.extensionPaths;
    if (!Array.isArray(extensionPaths) || !extensionPaths.every(entry => typeof entry === 'string' && path.isAbsolute(entry))) {
        throw new ProtocolFailure('invalidParams', 'extensionPaths must be a list of absolute directories.');
    }
    const storage = raw.storage;
    if (!isRecord(storage) || !['globalStoragePath', 'workspaceStoragePath', 'logPath']
        .every(key => typeof storage[key] === 'string' && path.isAbsolute(storage[key] as string))) {
        throw new ProtocolFailure('invalidParams', 'storage needs absolute globalStoragePath, workspaceStoragePath and logPath.');
    }
    if (raw.requestTimeoutMilliseconds !== undefined
        && (typeof raw.requestTimeoutMilliseconds !== 'number' || raw.requestTimeoutMilliseconds <= 0)) {
        throw new ProtocolFailure('invalidParams', 'requestTimeoutMilliseconds must be a positive number.');
    }
    if (raw.workspaceTrusted !== undefined && typeof raw.workspaceTrusted !== 'boolean') {
        throw new ProtocolFailure('invalidParams', 'workspaceTrusted must be a boolean.');
    }
    if (raw.commands !== undefined && (!Array.isArray(raw.commands) || !raw.commands.every(entry => typeof entry === 'string'))) {
        throw new ProtocolFailure('invalidParams', 'commands must be a list of command ids.');
    }
    return raw as unknown as InitializeParams;
}
