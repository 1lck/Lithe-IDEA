import { MAIN_RPC_CONTEXT, LanguagesMain, LanguagesExt, PluginInfo } from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { RPCProtocol } from '@theia/plugin-ext/lib/common/rpc-protocol';
import { MainContext } from './main-context';
import { parseUri, uriToString } from './uri';
import { ProtocolFailure } from '../protocol';
import { toCompletionItemKind } from '@theia/plugin-ext/lib/plugin/type-converters';
import { CancellationTokenSource } from '@theia/core/lib/common/cancellation';

import { SerializedDocumentFilter, MarkerData, Completion, CompletionResultDto, Range as TheiaRange } from '@theia/plugin-ext/lib/common/plugin-api-rpc-model';
import { Range } from '../protocol';
import { DocumentMirror } from './documents';
import { score } from '@theia/editor/lib/common/language-selector';
import { relative } from 'node:path';

const MAX_COMPLETION_LISTS = 32;
interface CompletionListEntry {
    handle: number;
    uri: string;
    result: CompletionResultDto;
}

/** Bridges provider registration and invocation without exposing Theia RPC types. */
export class LitheLanguagesMain implements Partial<LanguagesMain> {
    private readonly proxy: LanguagesExt;
    private readonly completionLists = new Map<string, CompletionListEntry>();
    private readonly latestCompletionRequests = new Map<string, number>();
    private nextCompletionRequest = 0;
    private readonly providers = new Map<number, { kind: string; selector: SerializedDocumentFilter[] }>();

    constructor(private readonly context: MainContext, rpc: RPCProtocol, private readonly documents: DocumentMirror) {
        this.proxy = rpc.getProxy(MAIN_RPC_CONTEXT.LANGUAGES_EXT);
    }

    $registerCompletionSupport(handle: number, _pluginInfo: PluginInfo, selector: SerializedDocumentFilter[], triggerCharacters: string[], supportsResolveDetails: boolean): void {
        this.register('completion', handle, selector, { triggerCharacters, supportsResolveDetails });
    }
    $registerHoverProvider(handle: number, _pluginInfo: PluginInfo, selector: SerializedDocumentFilter[]): void { this.register('hover', handle, selector, {}); }
    $registerDefinitionProvider(handle: number, _pluginInfo: PluginInfo, selector: SerializedDocumentFilter[]): void { this.register('definition', handle, selector, {}); }
    $registerReferenceProvider(handle: number, _pluginInfo: PluginInfo, selector: SerializedDocumentFilter[]): void { this.register('references', handle, selector, {}); }
    $unregister(handle: number): void {
        this.providers.delete(handle);
        for (const [token, entry] of this.completionLists) {
            if (entry.handle === handle) this.releaseCompletionList(token);
        }
        this.context.connection.notify('lithe/languageProviderUnregistered', { handle });
    }
    $changeDiagnostics(id: string, delta: [string, MarkerData[]][]): void {
        this.context.connection.notify('lithe/diagnosticsChanged', {
            id,
            delta: delta.map(([uri, markers]) => [uri, markers.map(marker => ({
                message: marker.message,
                range: normalizedRange(marker),
                severity: ({ 8: 1, 4: 2, 2: 3, 1: 4 } as Record<number, number>)[marker.severity] ?? null,
                source: marker.source ?? null,
                code: marker.code ?? null,
                tags: marker.tags ?? [],
                relatedInformation: (marker.relatedInformation ?? []).map(info => ({
                    uri: info.resource, range: normalizedRange(info), message: info.message
                }))
            }))])
        });
    }
    $clearDiagnostics(id: string): void { this.context.connection.notify('lithe/diagnosticsCleared', { id }); }

    async provide(kind: string, params: any, signal: AbortSignal): Promise<unknown> {
        const provider = this.providers.get(params.handle);
        if (!provider || provider.kind !== kind) {
            throw new ProtocolFailure('invalidParams', 'Language provider registration is no longer available.');
        }
        if (!Number.isInteger(params.line) || params.line < 1 || !Number.isInteger(params.character) || params.character < 1) {
            throw new ProtocolFailure('invalidParams', 'Language positions must be positive one-based integers.');
        }
        const handle = params.handle;
        const resource = parseUri(params.uri);
        const languageId = this.documents.languageId(params.uri);
        if (!languageId) throw new ProtocolFailure('documentNotFound', 'Language requests require an open document.');
        const selector = provider.selector.filter(filter => !filter.notebookType).map(filter => ({
            language: filter.language, scheme: filter.scheme,
            pattern: typeof filter.pattern === 'object' ? { base: filter.pattern.base, pattern: filter.pattern.pattern, pathToRelative: relative } : filter.pattern
        }));
        if (score(selector, resource.scheme, resource.fsPath, languageId, true) === 0) {
            return kind === 'completion' ? { completions: [] } : kind === 'hover' ? null : [];
        }
        const position = { lineNumber: params.line, column: params.character };
        const cancellation = new CancellationTokenSource();
        const cancel = () => cancellation.cancel();
        signal.addEventListener('abort', cancel, { once: true });
        if (signal.aborted) cancel();
        try {
            switch (kind) {
            case 'completion': {
                const key = `${handle}:${params.uri}`;
                const request = ++this.nextCompletionRequest;
                this.latestCompletionRequests.set(key, request);
                for (const [token, entry] of this.completionLists) {
                    if (entry.handle === handle && entry.uri === params.uri) this.releaseCompletionList(token);
                }
                let result: CompletionResultDto | undefined;
                try {
                    result = await this.proxy.$provideCompletionItems(handle, resource, position, { triggerKind: 0 }, cancellation.token);
                } catch (error) {
                    if (this.latestCompletionRequests.get(key) === request) this.latestCompletionRequests.delete(key);
                    throw error;
                }
                if (!result) {
                    if (this.latestCompletionRequests.get(key) === request) this.latestCompletionRequests.delete(key);
                    return { completions: [] };
                }
                if (signal.aborted || this.latestCompletionRequests.get(key) !== request || !this.providers.has(handle)) {
                    this.context.forward(this.proxy.$releaseCompletionItems(handle, result.id));
                    if (this.latestCompletionRequests.get(key) === request) this.latestCompletionRequests.delete(key);
                    throw new ProtocolFailure('cancelled', 'Completion request was superseded.');
                }
                this.latestCompletionRequests.delete(key);
                const token = String(request);
                this.completionLists.set(token, { handle, uri: params.uri, result });
                while (this.completionLists.size > MAX_COMPLETION_LISTS) {
                    this.releaseCompletionList(this.completionLists.keys().next().value!);
                }
                return { completions: result.completions.map((item, index) =>
                    normalizedCompletion(item, result.defaultRange.replace, { token, index })) };
            }
            case 'hover': {
                const result = await this.proxy.$provideHover(handle, resource, position, undefined, cancellation.token);
                return result ? { contents: result.contents.map(content => content.value).join('\n\n'), range: normalizedRange(result.range) } : null;
            }
            case 'definition':
            case 'references': {
                const result = kind === 'definition'
                    ? await this.proxy.$provideDefinition(handle, resource, position, cancellation.token)
                    : await this.proxy.$provideReferences(handle, resource, position, { includeDeclaration: true }, cancellation.token);
                return (result ? Array.isArray(result) ? result : [result] : []).map(location => ({
                    uri: uriToString(location.uri), range: normalizedRange(location.range)
                }));
            }
            default: throw this.context.unsupported(`LanguagesMain.${kind}`);
            }
        } finally {
            signal.removeEventListener('abort', cancel);
            cancellation.dispose();
        }
    }

    async resolveCompletion(params: any, signal: AbortSignal): Promise<unknown> {
        const entry = this.completionLists.get(params.token);
        const item = entry && Number.isInteger(params.index) && params.index >= 0
            ? entry.result.completions[params.index] : undefined;
        if (!entry || !item || entry.uri !== params.uri || !this.providers.has(entry.handle)) {
            throw new ProtocolFailure('invalidParams', 'Completion item has expired; request new completions.');
        }
        const cancellation = new CancellationTokenSource();
        const cancel = () => cancellation.cancel();
        signal.addEventListener('abort', cancel, { once: true });
        if (signal.aborted) cancel();
        try {
            const resolved = await this.proxy.$resolveCompletionItem(entry.handle, [entry.result.id, item.id], cancellation.token);
            if (signal.aborted || this.completionLists.get(params.token) !== entry) {
                throw new ProtocolFailure('cancelled', 'Completion item expired during resolution.');
            }
            return normalizedCompletion(resolved ?? item, entry.result.defaultRange.replace, { token: params.token, index: params.index });
        } finally {
            signal.removeEventListener('abort', cancel);
            cancellation.dispose();
        }
    }

    releaseDocument(uri: string): void {
        for (const [token, entry] of this.completionLists) {
            if (entry.uri === uri) this.releaseCompletionList(token);
        }
        // Invalidate in-flight requests even when no result has arrived yet.
        for (const key of this.latestCompletionRequests.keys()) {
            if (key.slice(key.indexOf(':') + 1) === uri) this.latestCompletionRequests.delete(key);
        }
    }

    private releaseCompletionList(token: string): void {
        const entry = this.completionLists.get(token);
        if (!entry) return;
        this.completionLists.delete(token);
        this.context.forward(this.proxy.$releaseCompletionItems(entry.handle, entry.result.id));
    }

    private register(kind: string, handle: number, selector: SerializedDocumentFilter[], options: unknown): void {
        this.providers.set(handle, { kind, selector });
        this.context.connection.notify('lithe/languageProviderRegistered', { kind, handle, selector: selector.map(({ language, scheme, pattern, notebookType }) => ({ language, scheme, pattern, notebookType })), options });
    }
}

/** Converts Monaco's internal range into Lithe's stable one-based wire range. */
function normalizedRange(range: TheiaRange | undefined): Range | null {
    return range ? { startLine: range.startLineNumber, startColumn: range.startColumn,
        endLine: range.endLineNumber, endColumn: range.endColumn } : null;
}

function normalizedCompletion(item: Completion, defaultRange: TheiaRange, data: { token: string; index: number }): unknown {
    return {
        label: typeof item.label === 'string' ? item.label : item.label.label,
        detail: item.detail ?? null,
        documentation: typeof item.documentation === 'string' ? item.documentation : item.documentation?.value ?? null,
        insertText: item.insertText,
        insertTextFormat: (item.insertTextRules ?? 0) & 4 ? 2 : 1,
        sortText: item.sortText ?? null,
        filterText: item.filterText ?? null,
        kind: toCompletionItemKind(item.kind) + 1,
        textEdit: { range: normalizedRange(item.range && 'startLineNumber' in item.range ? item.range : item.range?.replace ?? defaultRange), text: item.insertText },
        additionalTextEdits: (item.additionalTextEdits ?? []).map(edit => ({ range: normalizedRange(edit.range), text: edit.text })),
        data
    };
}
