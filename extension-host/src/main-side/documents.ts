import {
    DocumentsExt, DocumentsMain, EditorsAndDocumentsExt, ModelAddedData, TextEditorsMain,
    WorkspaceEditDto, WorkspaceTextEditDto
} from '@theia/plugin-ext/lib/common/plugin-api-rpc';
import { UriComponents } from '@theia/plugin-ext/lib/common/uri-components';
import {
    DocumentChangedParams, DocumentSnapshot, isRecord, Methods, ProtocolFailure, TextEdit
} from '../protocol';
import { MainContext } from './main-context';
import { parseUri, uriToString } from './uri';

interface MirroredDocument {
    languageId: string;
    version: number;
    eol: string;
}

/**
 * Version-checked mirror of the documents Lithe has shared with extensions.
 *
 * Lithe owns content, dirty state and saving. The mirror only forwards Lithe's
 * snapshots and changes into Theia's `ExtHostDocuments` and rejects anything
 * that would move a document's version backwards.
 */
export class DocumentMirror {
    private readonly documents = new Map<string, MirroredDocument>();

    constructor(
        private readonly editorsAndDocumentsExt: EditorsAndDocumentsExt,
        private readonly documentsExt: DocumentsExt,
        private readonly context: MainContext
    ) { }

    languageId(uri: string): string | undefined {
        return this.documents.get(normalizeUri(uri))?.languageId;
    }

    has(uri: string): boolean {
        return this.documents.has(normalizeUri(uri));
    }

    /**
     * Adds a snapshot. Re-sending an already mirrored version is a no-op, which
     * covers Lithe announcing a document the extension opened concurrently; a
     * newer version must arrive as `host/documentChanged` so no change is skipped.
     */
    open(snapshot: DocumentSnapshot): void {
        validateSnapshot(snapshot);
        const key = normalizeUri(snapshot.uri);
        const existing = this.documents.get(key);
        if (existing) {
            if (snapshot.version > existing.version) {
                throw new ProtocolFailure('invalidParams',
                    `Document ${key} is already open at version ${existing.version}; send host/documentChanged instead of reopening it.`,
                    { uri: key, version: existing.version });
            }
            return;
        }
        const eol = snapshot.text.includes('\r\n') ? '\r\n' : '\n';
        this.documents.set(key, { version: snapshot.version, eol, languageId: snapshot.languageId });
        const added: ModelAddedData = {
            uri: parseUri(key),
            versionId: snapshot.version,
            lines: snapshot.text.split(/\r\n|\r|\n/),
            EOL: eol,
            modeId: snapshot.languageId,
            languageId: snapshot.languageId,
            isDirty: snapshot.isDirty,
            encoding: 'utf8',
        };
        this.context.forward(this.editorsAndDocumentsExt.$acceptEditorsAndDocumentsDelta({ addedDocuments: [added] }));
    }

    change(params: DocumentChangedParams): void {
        const key = normalizeUri(params.uri);
        const existing = this.documents.get(key);
        if (!existing) {
            throw new ProtocolFailure('documentNotFound', `Document ${key} is not open in the extension host.`, { uri: key });
        }
        if (!Number.isInteger(params.version) || params.version <= existing.version) {
            throw new ProtocolFailure('staleDocumentVersion',
                `Change for ${key} has version ${params.version}, but the host already has version ${existing.version}.`,
                { uri: key, version: existing.version, receivedVersion: params.version });
        }
        existing.version = params.version;
        this.context.forward(this.documentsExt.$acceptModelChanged(parseUri(key), {
            changes: params.changes.map(change => ({
                range: {
                    startLineNumber: change.range.startLine,
                    startColumn: change.range.startColumn,
                    endLineNumber: change.range.endLine,
                    endColumn: change.range.endColumn,
                },
                rangeOffset: change.rangeOffset,
                rangeLength: change.rangeLength,
                text: change.text,
            })),
            eol: existing.eol,
            versionId: params.version,
            reason: undefined,
        }, params.isDirty));
    }

    saved(uri: string): void {
        const key = normalizeUri(uri);
        if (!this.documents.has(key)) {
            throw new ProtocolFailure('documentNotFound', `Document ${key} is not open in the extension host.`, { uri: key });
        }
        this.context.forward(this.documentsExt.$acceptModelSaved(parseUri(key)));
    }

    close(uri: string): void {
        const key = normalizeUri(uri);
        if (this.documents.delete(key)) {
            this.context.forward(this.editorsAndDocumentsExt.$acceptEditorsAndDocumentsDelta({ removedDocuments: [parseUri(key)] }));
        }
    }
}

export class LitheDocumentsMain implements Partial<DocumentsMain> {
    constructor(private readonly context: MainContext, private readonly mirror: DocumentMirror) { }

    async $tryOpenDocument(uri: UriComponents): Promise<boolean> {
        const key = uriToString(uri);
        if (this.mirror.has(key)) {
            return true;
        }
        const snapshot = await this.context.connection.request<DocumentSnapshot>(Methods.openDocument, { uri: key });
        this.mirror.open(snapshot);
        return true;
    }

    async $trySaveDocument(uri: UriComponents): Promise<boolean> {
        const result = await this.context.connection.request<{ saved: boolean }>(Methods.saveDocument, { uri: uriToString(uri) });
        return result.saved === true;
    }
}

export class LitheTextEditorsMain implements Partial<TextEditorsMain> {
    constructor(private readonly context: MainContext) { }

    async $tryApplyWorkspaceEdit(dto: WorkspaceEditDto): Promise<boolean> {
        const edits: TextEdit[] = [];
        for (const edit of dto.edits) {
            if (!WorkspaceTextEditDto.is(edit)) {
                throw this.context.unsupported('TextEditorsMain.$tryApplyWorkspaceEdit(fileOrNotebookEdit)');
            }
            if (edit.textEdit.insertAsSnippet) {
                throw this.context.unsupported('TextEditorsMain.$tryApplyWorkspaceEdit(snippet)');
            }
            edits.push({
                uri: uriToString(edit.resource),
                range: {
                    startLine: edit.textEdit.range.startLineNumber,
                    startColumn: edit.textEdit.range.startColumn,
                    endLine: edit.textEdit.range.endLineNumber,
                    endColumn: edit.textEdit.range.endColumn,
                },
                text: edit.textEdit.text,
                expectedVersion: edit.modelVersionId ?? null,
            });
        }
        // Lithe applies the edit to its own documents and sends host/documentChanged
        // before answering, so the extension observes the new text when this resolves.
        const result = await this.context.connection.request<{ applied: boolean }>(Methods.applyWorkspaceEdit, { edits });
        return result.applied === true;
    }
}

function normalizeUri(uri: string): string {
    return parseUri(uri).toString();
}

function validateSnapshot(snapshot: unknown): asserts snapshot is DocumentSnapshot {
    if (!isRecord(snapshot) || typeof snapshot.uri !== 'string' || typeof snapshot.text !== 'string'
        || typeof snapshot.languageId !== 'string' || !Number.isInteger(snapshot.version) || typeof snapshot.isDirty !== 'boolean') {
        throw new ProtocolFailure('invalidParams', 'A document snapshot needs uri, languageId, integer version, text and isDirty.');
    }
}
