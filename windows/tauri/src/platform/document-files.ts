import { invoke } from "./tauri-core";

export const FILE_ENCODINGS = ["UTF-8", "UTF-8 with BOM", "GBK", "GB18030", "Shift JIS", "Windows-1252"] as const;
export type FileEncoding = (typeof FILE_ENCODINGS)[number];

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
