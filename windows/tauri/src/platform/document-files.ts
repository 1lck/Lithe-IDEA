import { invoke } from "./tauri-core";

/** Stable IDs exchanged with the native adapter and persisted in sessions. */
export type FileEncoding = "UTF-8" | "UTF-8 with BOM" | "GBK" | "GB18030" | "Shift JIS" | "Windows-1252";

export type DocumentEncodingBom = "none" | "utf8";

/**
 * Single extension point for user-visible codecs. Add a descriptor here, then
 * map its ID in the macOS and Windows native adapters (see docs). Keeping the
 * capabilities explicit lets the picker grow without assuming every codec can
 * both read and write.
 */
export interface DocumentEncodingDescriptor {
  readonly id: FileEncoding;
  readonly stableId: string;
  readonly displayName: string;
  readonly aliases: readonly string[];
  readonly supportsRead: boolean;
  readonly supportsWrite: boolean;
  readonly bom: DocumentEncodingBom;
}

export const DOCUMENT_ENCODING_CATALOG: readonly DocumentEncodingDescriptor[] = [
  { id: "UTF-8", stableId: "utf-8", displayName: "UTF-8", aliases: ["utf8"], supportsRead: true, supportsWrite: true, bom: "none" },
  { id: "UTF-8 with BOM", stableId: "utf-8-bom", displayName: "UTF-8 with BOM", aliases: ["utf8-bom", "utf-8-bom"], supportsRead: true, supportsWrite: true, bom: "utf8" },
  { id: "GBK", stableId: "gbk", displayName: "GBK", aliases: ["cp936"], supportsRead: true, supportsWrite: true, bom: "none" },
  { id: "GB18030", stableId: "gb18030", displayName: "GB18030", aliases: [], supportsRead: true, supportsWrite: true, bom: "none" },
  { id: "Shift JIS", stableId: "shift-jis", displayName: "Shift JIS", aliases: ["shift-jis", "shift_jis"], supportsRead: true, supportsWrite: true, bom: "none" },
  { id: "Windows-1252", stableId: "windows-1252", displayName: "Windows-1252", aliases: ["cp1252"], supportsRead: true, supportsWrite: true, bom: "none" },
];

export const FILE_ENCODINGS = DOCUMENT_ENCODING_CATALOG.map(({ id }) => id) as readonly FileEncoding[];

export function getDocumentEncodingDescriptor(encoding: FileEncoding): DocumentEncodingDescriptor {
  const descriptor = DOCUMENT_ENCODING_CATALOG.find((candidate) => candidate.id === encoding);
  if (!descriptor) throw new Error(`Unknown document encoding: ${encoding}`);
  return descriptor;
}

export function getReadEncoding(value: { readEncoding?: FileEncoding; encoding?: FileEncoding }): FileEncoding | undefined {
  return value.readEncoding ?? value.encoding;
}

export function getSaveEncoding(value: { readEncoding?: FileEncoding; saveEncoding?: FileEncoding; encoding?: FileEncoding }): FileEncoding | undefined {
  return value.saveEncoding ?? getReadEncoding(value);
}

export interface DocumentReadDetails {
  content: string;
  encoding: FileEncoding;
  identity: string;
}

export function isLocalDocumentPath(path: string): boolean {
  return /^(?:[A-Za-z]:[\\/]|\/)/.test(path) && !/^\/\/(?:wsl\$|wsl\.localhost)\//i.test(path.replace(/\\/g, "/"));
}

export const readDocumentFile = (path: string): Promise<string | null> =>
  invoke("read_document_file", { path });

export const readDocumentFileDetails = (
  path: string,
  encoding?: FileEncoding,
): Promise<DocumentReadDetails | null> =>
  invoke("read_document_file_details", { path, encoding });

export type DocumentSaveOutcome = { status: "saved"; identity?: string } | { status: "conflict"; content: string | null; identity?: string };
export const saveDocumentFile = (
  path: string,
  content: string,
  expectedContent: string | null,
  encoding: FileEncoding = "UTF-8",
  expectedEncoding?: FileEncoding,
  expectedIdentity?: string,
): Promise<DocumentSaveOutcome> =>
  invoke("save_document_file", {
    path,
    content,
    expectedContent,
    encoding,
    expectedEncoding,
    expectedIdentity,
  });
