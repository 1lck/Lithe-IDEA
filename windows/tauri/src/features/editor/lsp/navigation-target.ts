import type { LspLocation } from "./lsp-client";
import { filePathFromUri } from "./workspace-edit";
import { getBufferByPath } from "@/features/editor/utils/buffer-index";
import type { OpenContentSpec, PaneContent } from "@/features/panes/types/pane-content.types";
import { getBaseName, normalizePath } from "@/utils/path-helpers";

interface NavigationBufferActions {
  openContent: (spec: OpenContentSpec) => string;
  setActiveBuffer: (bufferId: string) => void;
  updateBuffer: (buffer: PaneContent) => void;
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
  const withoutLeadingSlash = /^\/[A-Za-z]:\//.test(normalized)
    ? normalized.slice(1)
    : normalized;

  // Some servers return locations whose path still contains `..` segments.
  // Leaving them in produces buffer names like `../C:/…`, so resolve them.
  return resolvePathSegments(withoutLeadingSlash);
}

/**
 * Collapses `.` and `..` segments in an already forward-slashed path.
 * Preserves a drive prefix (`C:/`) or UNC prefix (`//host/`) when present.
 */
function resolvePathSegments(path: string): string {
  if (!path.includes("..") && !path.includes("./")) return path;

  const driveMatch = path.match(/^([A-Za-z]:\/)/);
  const uncMatch = path.match(/^(\/\/[^/]+\/)/);
  const prefix = driveMatch?.[1] ?? uncMatch?.[1] ?? (path.startsWith("/") ? "/" : "");
  const remainder = path.slice(prefix.length);

  const resolved: string[] = [];
  for (const segment of remainder.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      // A `..` that would escape an absolute root is meaningless; drop it.
      if (resolved.length > 0) resolved.pop();
      continue;
    }
    resolved.push(segment);
  }

  return prefix + resolved.join("/");
}

function virtualDocumentName(location: LspLocation): string {
  const displayPath = location.displayPath?.trim();
  const identityWithoutQuery = location.uri.split(/[?#]/, 1)[0];
  return getBaseName(displayPath || identityWithoutQuery, "Decompiled.java").replace(
    /\.class$/i,
    ".java",
  );
}

function physicalPathKey(path: string): string {
  const normalized = normalizePath(path);
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalized) ? normalized.toLowerCase() : normalized;
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
  const existingBuffer = getBufferByPath(buffers, targetPath);
  if (existingBuffer) {
    if (
      !filePath &&
      existingBuffer.type === "editor" &&
      (existingBuffer.lspDocument?.documentUri !== location.uri ||
        physicalPathKey(existingBuffer.lspDocument.sessionFilePath) !==
          physicalPathKey(sourceFilePath))
    ) {
      const content = await getVirtualDocument(sourceFilePath, location.uri);
      if (content == null) return null;
      actions.updateBuffer({
        ...existingBuffer,
        content,
        savedContent: content,
        isDirty: false,
        isVirtual: true,
        readOnly: true,
        language: "java",
        lspDocument: {
          documentUri: location.uri,
          sessionFilePath: sourceFilePath,
          languageId: "java",
        },
      });
    }
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
    lspDocument: {
      documentUri: location.uri,
      sessionFilePath: sourceFilePath,
      languageId: "java",
    },
  });
  actions.setActiveBuffer(bufferId);
  return bufferId;
}
