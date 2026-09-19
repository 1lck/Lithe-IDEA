// Test double for the Lithe side of the extension host protocol.
//
// It launches the built host (`dist/main.js`) with the real Node runtime, owns an
// authoritative in-memory document store the way Lithe does, and bounds every
// wait with a local deadline so a broken host fails the test instead of hanging.
import { spawn, ChildProcessWithoutNullStreams } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

export const HOST_ENTRY = path.resolve(import.meta.dir, '../../dist/main.js');
export const PROBE_EXTENSION = path.resolve(import.meta.dir, '../fixtures/extensions/lithe-probe');
const DEFAULT_DEADLINE_MILLISECONDS = 10_000;

export interface Range { startLine: number; startColumn: number; endLine: number; endColumn: number }
export interface LitheDocument { languageId: string; version: number; text: string; isDirty: boolean }
export interface Notification { method: string; params: any }
interface ProtocolError { code: string; message: string; details: unknown }

export class HostRequestError extends Error {
    constructor(readonly code: string, message: string, readonly details: unknown) {
        super(`${code}: ${message}`);
    }
}

type Handler = (params: any) => unknown | Promise<unknown>;

export class FakeLithe {
    readonly documents = new Map<string, LitheDocument>();
    readonly notifications: Notification[] = [];
    readonly receivedRequests: { method: string; params: any }[] = [];
    readonly litheCommands = new Map<string, Handler>();
    /** Responses whose id had no pending request: a host that answers twice or answers after cancel. */
    readonly unexpectedResponses: unknown[] = [];
    showMessageAnswer: number | null = null;
    stderr = '';

    private nextID = 1;
    private buffered = '';
    private readonly pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void }>();
    private readonly notificationWaiters = new Set<() => void>();
    private readonly exited: Promise<number | null>;
    private exitCode: number | null | undefined;

    private constructor(private readonly child: ChildProcessWithoutNullStreams, readonly directory: string) {
        child.stdout.setEncoding('utf8');
        child.stderr.setEncoding('utf8');
        child.stdout.on('data', (chunk: string) => this.receive(chunk));
        child.stderr.on('data', (chunk: string) => { this.stderr += chunk; });
        this.exited = new Promise(resolve => child.on('exit', code => {
            this.exitCode = code;
            for (const pending of this.pending.values()) {
                pending.reject(new Error(`Host exited with ${code} while a request was pending.\n${this.stderr}`));
            }
            this.pending.clear();
            this.wakeNotificationWaiters();
            resolve(code);
        }));
    }

    /** Spawns a host process. `directory` holds storage and workspace files and is removed by {@link dispose}. */
    static launch(directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lithe-extension-host-')),
        runtime?: { node: string; entrypoint: string }): FakeLithe {
        const node = runtime?.node ?? Bun.which('node');
        if (!node) {
            throw new Error('The extension host tests need Node.js on PATH; the host does not run under Bun.');
        }
        const entrypoint = runtime?.entrypoint ?? HOST_ENTRY;
        if (!fs.existsSync(entrypoint)) {
            throw new Error(`Build the host first (bun run build); ${entrypoint} is missing.`);
        }
        // Like the Lithe supervisor: on POSIX the host leads its own process group so the
        // whole tree, including grandchildren the host cannot see, can be ended at once.
        const child = spawn(node, [entrypoint], {
            stdio: ['pipe', 'pipe', 'pipe'],
            env: { ...process.env },
            detached: process.platform !== 'win32',
        });
        return new FakeLithe(child, directory);
    }

    get workspaceDirectory(): string {
        const workspace = path.join(this.directory, 'workspace');
        fs.mkdirSync(workspace, { recursive: true });
        return workspace;
    }

    uriOf(relativePath: string): string {
        return pathToFileURL(path.join(this.workspaceDirectory, relativePath)).toString();
    }

    initializeParams(overrides: Record<string, unknown> = {}): Record<string, unknown> {
        return {
            protocolVersion: 1,
            workspaceFolders: [{ uri: pathToFileURL(this.workspaceDirectory).toString(), name: 'workspace' }],
            extensionPaths: [PROBE_EXTENSION],
            storage: {
                globalStoragePath: path.join(this.directory, 'global-storage'),
                workspaceStoragePath: path.join(this.directory, 'workspace-storage'),
                logPath: path.join(this.directory, 'logs'),
            },
            commands: ['lithe.echo'],
            ...overrides,
        };
    }

    // Results are protocol JSON inspected by assertions, hence `any`.
    request(method: string, params: unknown, deadlineMilliseconds = DEFAULT_DEADLINE_MILLISECONDS): Promise<any> {
        const id = this.nextID++;
        return this.bounded(`${method} response`, deadlineMilliseconds, new Promise<unknown>((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
            this.send({ kind: 'request', id, method, params });
        }), () => this.pending.delete(id));
    }

    /** Sends a request and immediately cancels it, returning the eventual response. */
    requestAndCancel(method: string, params: unknown): Promise<unknown> {
        const id = this.nextID++;
        const response = this.bounded(`${method} response`, DEFAULT_DEADLINE_MILLISECONDS, new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
        }), () => this.pending.delete(id));
        this.send({ kind: 'request', id, method, params });
        this.send({ kind: 'cancel', id });
        return response;
    }

    notify(method: string, params: unknown): void {
        this.send({ kind: 'notification', method, params });
    }

    /** Opens a Lithe-owned document and announces it to the host. */
    openDocument(uri: string, text: string, languageId = 'java'): void {
        const document = { languageId, version: 1, text, isDirty: false };
        this.documents.set(uri, document);
        this.notify('host/documentOpened', { uri, ...document });
    }

    /** Edits a Lithe-owned document the way the Lithe editor would and announces the change. */
    editDocument(uri: string, range: Range, text: string): void {
        const document = this.requireDocument(uri);
        const change = applyEdit(document, range, text);
        document.version += 1;
        document.isDirty = true;
        this.notify('host/documentChanged', { uri, version: document.version, changes: [change], isDirty: true });
    }

    waitForNotification(predicate: (notification: Notification) => boolean, description: string,
        deadlineMilliseconds = DEFAULT_DEADLINE_MILLISECONDS): Promise<Notification> {
        const find = () => this.notifications.find(predicate);
        const existing = find();
        if (existing) {
            return Promise.resolve(existing);
        }
        let waiter: (() => void) | undefined;
        return this.bounded(description, deadlineMilliseconds, new Promise<Notification>((resolve, reject) => {
            waiter = () => {
                const found = find();
                if (found) {
                    resolve(found);
                } else if (this.exitCode !== undefined) {
                    reject(new Error(`Host exited before ${description}.\n${this.stderr}`));
                }
            };
            this.notificationWaiters.add(waiter);
        }), () => { if (waiter) { this.notificationWaiters.delete(waiter); } });
    }

    waitForRequest(predicate: (request: { method: string; params: any }) => boolean, description: string): Promise<void> {
        return this.waitForNotification(() => this.receivedRequests.some(predicate), description).then(() => undefined);
    }

    waitForExit(deadlineMilliseconds = DEFAULT_DEADLINE_MILLISECONDS): Promise<number | null> {
        return this.bounded('host process exit', deadlineMilliseconds, this.exited, () => undefined);
    }

    closeInput(): void {
        this.child.stdin.end();
    }

    /** Kills the host if it is still running and removes the test directory. Safe after failures. */
    async dispose(options: { keepDirectory?: boolean } = {}): Promise<void> {
        const running = this.exitCode === undefined;
        this.killProcessTree();
        if (running) {
            await this.bounded('killed host exit', DEFAULT_DEADLINE_MILLISECONDS, this.exited, () => undefined);
        }
        if (!options.keepDirectory) {
            fs.rmSync(this.directory, { recursive: true, force: true });
        }
    }

    /** Ends the host's process group; a no-op when every member has already exited. */
    private killProcessTree(): void {
        if (process.platform === 'win32' || this.child.pid === undefined) {
            if (this.exitCode === undefined) {
                this.child.kill('SIGKILL');
            }
            return;
        }
        try {
            process.kill(-this.child.pid, 'SIGKILL');
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== 'ESRCH') {
                throw error;
            }
        }
    }

    /** Lithe opens files that exist on disk on demand; so does the fake. */
    private loadFromDisk(uri: string): LitheDocument | undefined {
        if (!uri.startsWith('file:')) {
            return undefined;
        }
        const file = fileURLToPath(uri);
        if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
            return undefined;
        }
        const document = { languageId: languageOf(file), version: 1, text: fs.readFileSync(file, 'utf8'), isDirty: false };
        this.documents.set(uri, document);
        return document;
    }

    private requireDocument(uri: string): LitheDocument {
        const document = this.documents.get(uri);
        if (!document) {
            throw new Error(`Test document ${uri} is not open in the fake Lithe.`);
        }
        return document;
    }

    private async handleRequest(method: string, params: any): Promise<unknown> {
        this.receivedRequests.push({ method, params });
        this.wakeNotificationWaiters();
        switch (method) {
            case 'lithe/openDocument': {
                const document = this.documents.get(params.uri) ?? this.loadFromDisk(params.uri);
                if (!document) {
                    throw { code: 'documentNotFound', message: `No document ${params.uri}`, details: { uri: params.uri } };
                }
                return { uri: params.uri, ...document };
            }
            case 'lithe/applyWorkspaceEdit': {
                for (const edit of params.edits) {
                    const document = this.documents.get(edit.uri);
                    if (!document || (edit.expectedVersion !== null && edit.expectedVersion !== document.version)) {
                        return { applied: false };
                    }
                }
                for (const edit of params.edits) {
                    this.editDocument(edit.uri, edit.range, edit.text);
                }
                return { applied: true };
            }
            case 'lithe/saveDocument': {
                const document = this.requireDocument(params.uri);
                document.isDirty = false;
                this.notify('host/documentSaved', { uri: params.uri });
                return { saved: true };
            }
            case 'lithe/executeCommand': {
                const handler = this.litheCommands.get(params.command);
                if (!handler) {
                    throw { code: 'commandNotFound', message: `Lithe has no command ${params.command}`, details: null };
                }
                return handler(params.arguments);
            }
            case 'lithe/findFiles': {
                // Good enough for tests: no exclude or ignore rules, one workspace folder.
                const base = params.baseUri ? fileURLToPath(params.baseUri) : this.workspaceDirectory;
                const matches = [...new Bun.Glob(params.include).scanSync({ cwd: base, onlyFiles: true })].sort();
                return { uris: matches.map(match => pathToFileURL(path.join(base, match)).toString()) };
            }
            case 'lithe/showMessage':
                return { selectedIndex: this.showMessageAnswer };
            default:
                throw { code: 'methodNotFound', message: method, details: null };
        }
    }

    private receive(chunk: string): void {
        this.buffered += chunk;
        let newline = this.buffered.indexOf('\n');
        while (newline >= 0) {
            const line = this.buffered.slice(0, newline);
            this.buffered = this.buffered.slice(newline + 1);
            newline = this.buffered.indexOf('\n');
            if (line.trim().length === 0) {
                continue;
            }
            let message: any;
            try {
                message = JSON.parse(line);
            } catch {
                // Anything that is not protocol JSON on stdout is a host bug the tests must see.
                this.notifications.push({ method: 'test/corruptStdout', params: { line } });
                this.wakeNotificationWaiters();
                continue;
            }
            if (message.kind === 'response') {
                const pending = this.pending.get(message.id);
                this.pending.delete(message.id);
                if (!pending) {
                    this.unexpectedResponses.push(message);
                }
                if (message.error) {
                    const error = message.error as ProtocolError;
                    pending?.reject(new HostRequestError(error.code, error.message, error.details));
                } else {
                    pending?.resolve(message.result);
                }
            } else if (message.kind === 'notification') {
                this.notifications.push({ method: message.method, params: message.params });
                this.wakeNotificationWaiters();
            } else if (message.kind === 'request') {
                this.handleRequest(message.method, message.params).then(
                    result => this.send({ kind: 'response', id: message.id, result: result ?? null }),
                    error => this.send({
                        kind: 'response', id: message.id,
                        error: error && typeof error.code === 'string' ? error : { code: 'internalError', message: String(error), details: null },
                    }));
            }
        }
    }

    private wakeNotificationWaiters(): void {
        for (const waiter of [...this.notificationWaiters]) {
            waiter();
        }
    }

    private send(message: unknown): void {
        this.child.stdin.write(JSON.stringify(message) + '\n');
    }

    private bounded<T>(description: string, milliseconds: number, promise: Promise<T>, cleanup: () => void): Promise<T> {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const deadline = new Promise<never>((_, reject) => {
            timer = setTimeout(() => {
                reject(new Error(`Timed out after ${milliseconds} ms waiting for ${description}.\nHost stderr:\n${this.stderr}`));
            }, milliseconds);
        });
        return Promise.race([promise, deadline]).finally(() => {
            clearTimeout(timer);
            cleanup();
        });
    }
}

function languageOf(file: string): string {
    const extension = path.extname(file).toLowerCase();
    return { '.java': 'java', '.xml': 'xml', '.json': 'json', '.properties': 'properties' }[extension] ?? 'plaintext';
}

/** Applies a one-based range edit and returns the change in protocol form. */
function applyEdit(document: LitheDocument, range: Range, text: string) {
    const start = offsetAt(document.text, range.startLine, range.startColumn);
    const end = offsetAt(document.text, range.endLine, range.endColumn);
    document.text = document.text.slice(0, start) + text + document.text.slice(end);
    return { range, rangeOffset: start, rangeLength: end - start, text };
}

function offsetAt(text: string, line: number, column: number): number {
    let offset = 0;
    for (let current = 1; current < line; current++) {
        const newline = text.indexOf('\n', offset);
        if (newline < 0) {
            throw new Error(`Line ${line} is outside the test document.`);
        }
        offset = newline + 1;
    }
    return offset + column - 1;
}
