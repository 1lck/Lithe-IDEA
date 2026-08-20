import type { LspLocation } from "./lsp-client";
import { filePathFromUri } from "./workspace-edit";
import type { OpenContentSpec, PaneContent } from "@/features/panes/types/pane-content.types";
import { getBaseName, normalizePath } from "@/utils/path-helpers";

interface NavigationBufferActions {
  openContent: (spec: OpenContentSpec) => string;
  setActiveBuffer: (bufferId: string) => void;
}

interface OpenLspNavigationLocationOptions {
  location: LspLocation;
  sourceFilePath: string;
  buffers: readonly PaneContent[];
  actions: NavigationBufferActions;
  getVirtualDocument: (sourceFilePath: string, virtualUri: string) => Promise<string | null>;
  readFileContent: (filePath: string) => Promise<string>;
}

function physicalPath(location: LspLocation): string | null {
  const explicitPath = location.filePath?.trim();
  const uriPath =
    location.uri.startsWith("file://") || !location.uri.includes("://")
      ? filePathFromUri(location.uri)
      : null;
  const path = explicitPath || uriPath;
  if (!path) return null;

  const normalized = normalizePath(path);
  return /^\/[A-Za-z]:\//.test(normalized) ? normalized.slice(1) : normalized;
}

function virtualDocumentName(location: LspLocation): string {
  const displayPath = location.displayPath?.trim();
  const identityWithoutQuery = location.uri.split(/[?#]/, 1)[0];
  return getBaseName(displayPath || identityWithoutQuery, "Decompiled.java").replace(
    /\.class$/i,
    ".java",
  );
}

export async function openLspNavigationLocation({
  location,
  sourceFilePath,
  buffers,
  actions,
  getVirtualDocument,
  readFileContent,
}: OpenLspNavigationLocationOptions): Promise<string | null> {
  const filePath = physicalPath(location);
  const targetPath = filePath ?? location.uri;
  const existingBuffer = buffers.find((buffer) => buffer.path === targetPath);
  if (existingBuffer) {
    actions.setActiveBuffer(existingBuffer.id);
    return existingBuffer.id;
  }

  if (filePath) {
    const content = await readFileContent(filePath);
    const bufferId = actions.openContent({
      type: "editor",
      path: filePath,
      name: getBaseName(filePath),
      content,
    });
    actions.setActiveBuffer(bufferId);
    return bufferId;
  }

  const content = await getVirtualDocument(sourceFilePath, location.uri);
  if (content == null) return null;

  const bufferId = actions.openContent({
    type: "editor",
    path: location.uri,
    name: virtualDocumentName(location),
    content,
    isVirtual: true,
    readOnly: true,
    language: "java",
  });
  actions.setActiveBuffer(bufferId);
  return bufferId;
}
