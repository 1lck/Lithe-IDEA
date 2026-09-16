import { invoke } from "./tauri-core";

export function isLocalDocumentPath(path: string): boolean {
  return /^(?:[A-Za-z]:[\\/]|\/)/.test(path) && !/^\/\/(?:wsl\$|wsl\.localhost)\//i.test(path.replace(/\\/g, "/"));
}

export const readDocumentFile = (path: string): Promise<string | null> =>
  invoke("read_document_file", { path });

export type DocumentSaveOutcome = { status: "saved" } | { status: "conflict"; content: string | null };
export const saveDocumentFile = (path: string, content: string, expectedContent: string | null): Promise<DocumentSaveOutcome> =>
  invoke("save_document_file", { path, content, expectedContent });
