// Lithe <-> VS Code extension host protocol, version 1.
//
// This file is the host-side copy of `shared/contracts/vscode-extension-host.md`.
// Theia's internal RPC types never cross this boundary: everything Lithe sees is
// plain UTF-8 JSON defined here, one message per line on stdin/stdout.

export const PROTOCOL_VERSION = 1;

export type RequestID = number;

export interface RequestMessage {
    kind: 'request';
    id: RequestID;
    method: string;
    params: unknown;
}

export interface NotificationMessage {
    kind: 'notification';
    method: string;
    params: unknown;
}

export interface ResponseMessage {
    kind: 'response';
    id: RequestID;
    result?: unknown;
    error?: ProtocolError;
}

/** Cancels a request previously sent by the peer that receives this message. */
export interface CancelMessage {
    kind: 'cancel';
    id: RequestID;
}

export type Message = RequestMessage | NotificationMessage | ResponseMessage | CancelMessage;

export interface ProtocolError {
    code: ErrorCode;
    message: string;
    details: Record<string, unknown> | null;
}

export type ErrorCode =
    | 'invalidParams'
    | 'methodNotFound'
    | 'notInitialized'
    | 'alreadyInitialized'
    | 'cancelled'
    | 'timeout'
    | 'commandNotFound'
    | 'commandFailed'
    | 'documentNotFound'
    | 'staleDocumentVersion'
    | 'unsupportedApi'
    | 'shuttingDown'
    | 'internalError';

export class ProtocolFailure extends Error {
    constructor(
        readonly code: ErrorCode,
        message: string,
        readonly details: Record<string, unknown> | null = null
    ) {
        super(message);
    }

    toProtocolError(): ProtocolError {
        return { code: this.code, message: this.message, details: this.details };
    }
}

/** Method names. The prefix states who owns the handler: `host/` is served by the host, `lithe/` by Lithe. */
export const Methods = {
    // Lithe -> host requests
    initialize: 'host/initialize',
    activateByEvent: 'host/activateByEvent',
    executeExtensionCommand: 'host/executeCommand',
    shutdown: 'host/shutdown',
    // Lithe -> host notifications (Lithe owns document content; the host mirrors it)
    documentOpened: 'host/documentOpened',
    documentChanged: 'host/documentChanged',
    documentSaved: 'host/documentSaved',
    documentClosed: 'host/documentClosed',

    // Host -> Lithe requests
    executeLitheCommand: 'lithe/executeCommand',
    openDocument: 'lithe/openDocument',
    saveDocument: 'lithe/saveDocument',
    applyWorkspaceEdit: 'lithe/applyWorkspaceEdit',
    findFiles: 'lithe/findFiles',
    showMessage: 'lithe/showMessage',
    // Host -> Lithe notifications
    log: 'lithe/log',
    unsupportedApi: 'lithe/unsupportedApi',
    commandRegistered: 'lithe/commandRegistered',
    commandUnregistered: 'lithe/commandUnregistered',
    progress: 'lithe/progress',
} as const;

/** One-based line and one-based UTF-16 column positions, matching Lithe's editor contracts. */
export interface Range {
    startLine: number;
    startColumn: number;
    endLine: number;
    endColumn: number;
}

export interface WorkspaceFolder {
    uri: string;
    name: string;
}

export interface InitializeParams {
    protocolVersion: number;
    workspaceFolders: WorkspaceFolder[];
    /** Absolute directories that contain an unpacked extension `package.json`. */
    extensionPaths: string[];
    storage: {
        globalStoragePath: string;
        workspaceStoragePath: string;
        logPath: string;
    };
    configuration?: {
        /** Applied on top of the defaults contributed by the loaded extensions. */
        defaults?: Record<string, unknown>;
        user?: Record<string, unknown>;
        workspace?: Record<string, unknown>;
    };
    environment?: {
        language?: string;
        appName?: string;
        shell?: string;
    };
    /**
     * Lithe's trust decision for the workspace, exposed as `workspace.isTrusted`.
     * Defaults to `false`; the host never asks the user itself.
     */
    workspaceTrusted?: boolean;
    /** Lithe command ids extensions may execute; reported by `vscode.commands.getCommands()`. */
    commands?: string[];
    /** Upper bound for every host -> Lithe request. Defaults to 30 seconds. */
    requestTimeoutMilliseconds?: number;
}

export interface ExtensionSummary {
    id: string;
    version: string;
    displayName: string | null;
    activationEvents: string[];
    commands: { command: string; title: string | null }[];
}

export interface InitializeResult {
    protocolVersion: number;
    apiVersion: string;
    extensions: ExtensionSummary[];
    failedExtensions: { path: string; message: string }[];
}

export interface DocumentSnapshot {
    uri: string;
    languageId: string;
    version: number;
    text: string;
    isDirty: boolean;
}

export interface DocumentChange {
    range: Range;
    rangeOffset: number;
    rangeLength: number;
    text: string;
}

export interface DocumentChangedParams {
    uri: string;
    version: number;
    changes: DocumentChange[];
    isDirty: boolean;
}

export interface TextEdit {
    uri: string;
    range: Range;
    text: string;
    /** When present, Lithe must reject the whole edit if the document version differs. */
    expectedVersion: number | null;
}

/** `vscode.workspace.findFiles`. Patterns use VS Code glob syntax; Lithe applies its own exclude and ignore rules. */
export interface FindFilesParams {
    include: string;
    /** Folder the include pattern is relative to; `null` means every workspace folder. */
    baseUri: string | null;
    exclude: string | null;
    /** Apply the user's `files.exclude` configuration. */
    useDefaultExcludes: boolean;
    useIgnoreFiles: boolean;
    maxResults: number | null;
}

export interface ShowMessageParams {
    severity: 'error' | 'warning' | 'info';
    message: string;
    detail: string | null;
    modal: boolean;
    actions: string[];
}

export interface ProgressParams {
    id: string;
    phase: 'start' | 'report' | 'end';
    title: string | null;
    message: string | null;
    increment: number | null;
    cancellable: boolean;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
}
