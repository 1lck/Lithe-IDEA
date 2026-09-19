import { Methods, isRecord, Message, ProtocolError, ProtocolFailure, RequestID } from './protocol';

export type RequestHandler = (params: unknown, signal: AbortSignal) => Promise<unknown>;
export type NotificationHandler = (params: unknown) => void;

export interface Timers {
    setTimeout(callback: () => void, milliseconds: number): unknown;
    clearTimeout(handle: unknown): void;
}

const realTimers: Timers = {
    setTimeout: (callback, milliseconds) => setTimeout(callback, milliseconds),
    clearTimeout: handle => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

interface PendingRequest {
    method: string;
    resolve(value: unknown): void;
    reject(reason: ProtocolFailure): void;
    deadline: unknown;
}

/**
 * Newline-delimited JSON peer for the Lithe protocol.
 *
 * Both sides may issue requests. Every outgoing request has a deadline; when it
 * expires the peer is told to cancel and the caller receives `timeout`, so a
 * late response can never resolve a caller that already gave up.
 */
export class LitheConnection {
    private nextID: RequestID = 1;
    private readonly pending = new Map<RequestID, PendingRequest>();
    private readonly incoming = new Map<RequestID, AbortController>();
    private readonly requestHandlers = new Map<string, RequestHandler>();
    private readonly notificationHandlers = new Map<string, NotificationHandler>();
    private readonly closeListeners: (() => void)[] = [];
    private buffered = '';
    private closed = false;

    constructor(
        private readonly writeLine: (line: string) => void,
        private readonly diagnostics: (message: string) => void,
        private readonly timers: Timers = realTimers,
        public requestTimeoutMilliseconds = 30_000
    ) { }

    onRequest(method: string, handler: RequestHandler): void {
        this.requestHandlers.set(method, handler);
    }

    onNotification(method: string, handler: NotificationHandler): void {
        this.notificationHandlers.set(method, handler);
    }

    onClose(listener: () => void): void {
        this.closeListeners.push(listener);
    }

    /** Feeds raw UTF-8 input; complete lines are dispatched in arrival order. */
    receive(chunk: string): void {
        this.buffered += chunk;
        let newline = this.buffered.indexOf('\n');
        while (newline >= 0) {
            const line = this.buffered.slice(0, newline).trim();
            this.buffered = this.buffered.slice(newline + 1);
            if (line.length > 0) {
                this.dispatch(line);
            }
            newline = this.buffered.indexOf('\n');
        }
    }

    request<T>(method: string, params: unknown): Promise<T> {
        if (this.closed) {
            return Promise.reject(new ProtocolFailure('shuttingDown', `Connection closed before ${method} was sent.`));
        }
        const id = this.nextID++;
        return new Promise<T>((resolve, reject) => {
            const deadline = this.timers.setTimeout(() => {
                if (this.pending.delete(id)) {
                    this.send({ kind: 'cancel', id });
                    reject(new ProtocolFailure('timeout', `Lithe did not answer ${method} within ${this.requestTimeoutMilliseconds} ms.`,
                        { method, timeoutMilliseconds: this.requestTimeoutMilliseconds }));
                }
            }, this.requestTimeoutMilliseconds);
            this.pending.set(id, { method, resolve: value => resolve(value as T), reject, deadline });
            this.send({ kind: 'request', id, method, params });
        });
    }

    notify(method: string, params: unknown): void {
        if (!this.closed) {
            this.send({ kind: 'notification', method, params });
        }
    }

    /** Fails every outstanding request and stops accepting new work. Idempotent. */
    close(): void {
        if (this.closed) {
            return;
        }
        this.closed = true;
        for (const [id, pending] of this.pending) {
            this.timers.clearTimeout(pending.deadline);
            pending.reject(new ProtocolFailure('shuttingDown', `Connection closed while waiting for ${pending.method}.`));
            this.pending.delete(id);
        }
        for (const controller of this.incoming.values()) {
            controller.abort();
        }
        this.incoming.clear();
        for (const listener of this.closeListeners) {
            listener();
        }
    }

    private dispatch(line: string): void {
        let message: unknown;
        try {
            message = JSON.parse(line);
        } catch {
            this.diagnostics(`Discarded malformed protocol line (${line.length} bytes).`);
            return;
        }
        if (!isRecord(message) || typeof message.kind !== 'string') {
            this.diagnostics('Discarded protocol message without a kind.');
            return;
        }
        const typed = message as unknown as Message;
        switch (typed.kind) {
            case 'response': return this.handleResponse(typed.id, typed.result, typed.error);
            case 'request': return this.handleRequest(typed.id, typed.method, typed.params);
            case 'notification': return this.handleNotification(typed.method, typed.params);
            case 'cancel': return this.handleCancel(typed.id);
            default: this.diagnostics(`Discarded protocol message of unknown kind ${String(message.kind)}.`);
        }
    }

    private handleResponse(id: RequestID, result: unknown, error: ProtocolError | undefined): void {
        const pending = this.pending.get(id);
        if (!pending) {
            // Late answer to a request that already timed out or was cancelled.
            return;
        }
        this.pending.delete(id);
        this.timers.clearTimeout(pending.deadline);
        if (error) {
            pending.reject(new ProtocolFailure(error.code, error.message, error.details ?? null));
        } else {
            pending.resolve(result ?? null);
        }
    }

    private handleRequest(id: RequestID, method: string, params: unknown): void {
        if (typeof id !== 'number' || typeof method !== 'string') {
            this.diagnostics('Discarded request without a numeric id and method.');
            return;
        }
        const handler = this.requestHandlers.get(method);
        if (!handler) {
            this.respondError(id, new ProtocolFailure('methodNotFound', `The extension host does not implement ${method}.`));
            return;
        }
        const controller = new AbortController();
        this.incoming.set(id, controller);
        handler(params ?? null, controller.signal).then(
            result => {
                if (this.incoming.get(id) === controller) {
                    this.incoming.delete(id);
                    this.send({ kind: 'response', id, result: result ?? null });
                }
            },
            error => {
                if (this.incoming.get(id) === controller) {
                    this.incoming.delete(id);
                    this.respondError(id, toFailure(error));
                }
            });
    }

    private handleNotification(method: string, params: unknown): void {
        const handler = this.notificationHandlers.get(method);
        if (!handler) {
            this.diagnostics(`Ignored notification ${method} without a handler.`);
            return;
        }
        try {
            handler(params ?? null);
        } catch (error) {
            // Notifications have no response, so a rejected one is reported through the log with its stable code.
            const failure = toFailure(error);
            const message = `Notification ${method} failed (${failure.code}): ${failure.message}`;
            this.diagnostics(message);
            this.notify(Methods.log, { level: 'error', source: 'protocol', message });
        }
    }

    private handleCancel(id: RequestID): void {
        const controller = this.incoming.get(id);
        if (!controller) {
            return;
        }
        // Answer immediately; whatever the handler produces later is discarded.
        this.incoming.delete(id);
        controller.abort();
        this.respondError(id, new ProtocolFailure('cancelled', 'Lithe cancelled the request.'));
    }

    private respondError(id: RequestID, failure: ProtocolFailure): void {
        this.send({ kind: 'response', id, error: failure.toProtocolError() });
    }

    private send(message: Message): void {
        this.writeLine(JSON.stringify(message) + '\n');
    }
}

export function toFailure(error: unknown): ProtocolFailure {
    if (error instanceof ProtocolFailure) {
        return error;
    }
    const message = error instanceof Error ? error.message : String(error);
    return new ProtocolFailure('internalError', message);
}
