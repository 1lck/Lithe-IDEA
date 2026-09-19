import { format } from 'util';
import {
    EnvMain, LoggerMain, LogLevel, MainMessageItem, MainMessageOptions, MainMessageType,
    FindFilesOptions, MessageRegistryMain, NotificationMain, WorkspaceMain
} from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { UriComponents } from '@theia/plugin-ext/lib/common/uri-components';
import { OperatingSystem } from '@theia/plugin-ext/lib/plugin/types-impl';
import { FindFilesParams, Methods, ProgressParams, ShowMessageParams } from '../protocol';
import { MainContext } from './main-context';
import { parseUri } from './uri';

const LOG_LEVELS: Record<number, string> = {
    [LogLevel.Trace]: 'trace',
    [LogLevel.Debug]: 'debug',
    [LogLevel.Info]: 'info',
    [LogLevel.Warn]: 'warning',
    [LogLevel.Error]: 'error',
};

/** Receives the plugin host's `console.*` output, which Theia routes through RPC. */
export class LitheLoggerMain implements LoggerMain {
    constructor(private readonly context: MainContext) { }

    $log(level: LogLevel, name: string | undefined, message: string, params: unknown[]): void {
        this.context.connection.notify(Methods.log, {
            level: LOG_LEVELS[level] ?? 'info',
            source: name ?? null,
            // Theia passes the error of a failed activation as a parameter; keep it.
            message: params?.length ? format(message, ...params) : message,
        });
    }
}

export class LitheMessageRegistryMain implements MessageRegistryMain {
    constructor(private readonly context: MainContext) { }

    async $showMessage(type: MainMessageType, message: string, options: MainMessageOptions, actions: MainMessageItem[]): Promise<number | undefined> {
        const params: ShowMessageParams = {
            severity: type === MainMessageType.Error ? 'error' : type === MainMessageType.Warning ? 'warning' : 'info',
            message,
            detail: options.detail ?? null,
            modal: options.modal === true,
            actions: actions.map(action => action.title),
        };
        const result = await this.context.connection.request<{ selectedIndex: number | null }>(Methods.showMessage, params);
        // Theia identifies an action by its index in `actions`; dismissing picks the close affordance, if any.
        const index = result.selectedIndex;
        if (typeof index === 'number' && Number.isInteger(index) && index >= 0 && index < actions.length) {
            return index;
        }
        return options.onCloseActionHandle;
    }
}

/** Forwards `window.withProgress` to Lithe. Lithe decides where and whether to show it. */
export class LitheNotificationMain implements NotificationMain {
    private nextID = 1;

    constructor(private readonly context: MainContext) { }

    async $startProgress(options: NotificationMain.StartProgressOptions): Promise<string> {
        const id = `progress-${this.nextID++}`;
        this.send({ id, phase: 'start', title: options.title ?? null, message: null, increment: null, cancellable: options.cancellable === true });
        return id;
    }

    $updateProgress(id: string, report: NotificationMain.ProgressReport): void {
        this.send({ id, phase: 'report', title: null, message: report.message ?? null, increment: report.increment ?? null, cancellable: false });
    }

    $stopProgress(id: string): void {
        this.send({ id, phase: 'end', title: null, message: null, increment: null, cancellable: false });
    }

    private send(params: ProgressParams): void {
        this.context.connection.notify(Methods.progress, params);
    }
}

/**
 * `vscode.env` values that Theia resolves on the main side. The host process
 * environment is the one Lithe chose when it launched the host.
 */
export class LitheEnvMain implements EnvMain {
    async $getEnvVariable(name: string): Promise<string | undefined> {
        return process.env[name];
    }

    async $getClientOperatingSystem(): Promise<OperatingSystem> {
        switch (process.platform) {
            case 'win32': return OperatingSystem.Windows;
            case 'darwin': return OperatingSystem.OSX;
            default: return OperatingSystem.Linux;
        }
    }
}

/** The workspace-level parts of `vscode.workspace` that Lithe already models. */
export class LitheWorkspaceMain implements Partial<WorkspaceMain> {
    private trusted = false;

    constructor(private readonly context: MainContext) { }

    setTrusted(trusted: boolean): void {
        this.trusted = trusted;
    }

    /** Trust is decided by Lithe before the host starts; extensions only learn the answer. */
    async $requestWorkspaceTrust(): Promise<boolean> {
        return this.trusted;
    }

    /** Lithe's search owns exclude rules, ignore files and indexing, so the host does not walk the disk itself. */
    async $startFileSearch(includePattern: string, includeFolder: string | undefined, options: FindFilesOptions): Promise<UriComponents[]> {
        const params: FindFilesParams = {
            include: includePattern,
            baseUri: includeFolder ?? null,
            exclude: options.exclude ? options.exclude : null,
            useDefaultExcludes: options.useDefaultExcludes !== false,
            useIgnoreFiles: options.useIgnoreFiles === true,
            maxResults: typeof options.maxResults === 'number' ? options.maxResults : null,
        };
        const result = await this.context.connection.request<{ uris: string[] }>(Methods.findFiles, params);
        const uris = Array.isArray(result.uris) ? result.uris : [];
        return (params.maxResults === null ? uris : uris.slice(0, params.maxResults)).map(uri => parseUri(uri));
    }

    async $getWorkspace(): Promise<undefined> {
        // Lithe opens folders, never `.code-workspace` files, so `workspace.workspaceFile`
        // is `undefined`, exactly as in VS Code for a folder window.
        return undefined;
    }
}
