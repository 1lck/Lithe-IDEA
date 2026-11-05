import { executeCore } from "@/core/lithe-core-client";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { requireLoadedBufferContent } from "@/features/editor/utils/buffer-load-state";
import {
  areBufferPathsEqual,
  getSourceEditorBufferByPath,
} from "@/features/editor/utils/buffer-index";
import { readFileContent } from "@/features/file-system/controllers/file-operations";
import { writeFile } from "@/features/file-system/controllers/platform";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import {
  isLocalDocumentPath,
  readDocumentFileDetails,
  saveDocumentFile,
  type DocumentReadDetails,
} from "@/platform/document-files";
import type { ContentSearchOptions } from "../types/global-search.types";

interface ReplaceTarget {
  filePath: string;
  line: number;
  column: number;
}

interface SourceContent {
  bufferId: string | null;
  content: string;
  disk?: DocumentReadDetails;
}

const REPLACE_ALL_CONCURRENCY = 8;

type BufferStore = ReturnType<typeof useBufferStore.getStore>;
interface ReplacementOwner {
  workspaceId: string;
  lifetime: ReturnType<typeof workspaceRuntimeRegistry.getWorkspace>;
  buffers: BufferStore;
}

function replacementOwner(workspaceId: string): ReplacementOwner {
  return {
    workspaceId,
    lifetime: workspaceRuntimeRegistry.getWorkspace(workspaceId),
    buffers: useBufferStore.getStore(workspaceId),
  };
}

function checkOwner(owner: ReplacementOwner): void {
  if (
    !owner.lifetime ||
    workspaceRuntimeRegistry.getWorkspace(owner.workspaceId) !== owner.lifetime
  )
    throw changedSourceError();
}

function changedSourceError(): Error {
  return new Error(
    createTranslator(useSettingsStore.getState().settings.displayLanguage)(
      "search.replaceMatchesFailed",
    ),
  );
}

function getSourceContent(owner: ReplacementOwner, filePath: string): SourceContent | null {
  checkOwner(owner);
  const buffers = owner.buffers.getState().buffers;
  const buffer =
    getSourceEditorBufferByPath(buffers, filePath) ??
    buffers.find(
      (item): item is EditorContent =>
        item.type === "editor" && !item.isVirtual && areBufferPathsEqual(item.path, filePath),
    );
  if (!buffer) return null;
  requireLoadedBufferContent(buffer);
  if (buffer.readOnly) throw changedSourceError();
  return { bufferId: buffer.id, content: buffer.content };
}

function getOpenSourceContentByPath(
  owner: ReplacementOwner,
  filePaths: string[],
): Map<string, SourceContent> {
  const sources = new Map<string, SourceContent>();
  for (const path of filePaths) {
    const source = getSourceContent(owner, path);
    if (source) sources.set(path, source);
  }
  return sources;
}

async function readSource(
  owner: ReplacementOwner,
  filePath: string,
  openSources?: ReadonlyMap<string, SourceContent>,
): Promise<SourceContent> {
  checkOwner(owner);
  const openSource = openSources?.get(filePath) ?? getSourceContent(owner, filePath);
  if (openSource) return openSource;
  if (isLocalDocumentPath(filePath.replace(/\\/g, "/"))) {
    const disk = await readDocumentFileDetails(filePath);
    if (!disk) throw changedSourceError();
    return { bufferId: null, content: disk.content, disk };
  }
  return { bufferId: null, content: await readFileContent(filePath) };
}

async function writeSource(
  owner: ReplacementOwner,
  filePath: string,
  source: SourceContent,
  content: string,
): Promise<void> {
  const currentBuffer = getSourceContent(owner, filePath);
  if (source.bufferId) {
    if (
      !currentBuffer ||
      currentBuffer.bufferId !== source.bufferId ||
      currentBuffer.content !== source.content
    ) {
      throw changedSourceError();
    }
    owner.buffers.getState().actions.updateBufferContent(source.bufferId, content, true);
    return;
  }
  if (currentBuffer) throw changedSourceError();
  if (source.disk) {
    const result = await saveDocumentFile(
      filePath,
      content,
      source.content,
      source.disk.encoding,
      source.disk.encoding,
      source.disk.identity,
    );
    if (result.status !== "saved") throw changedSourceError();
    return;
  }
  // Provider files do not expose native byte identities; detect changes before writing.
  if ((await readFileContent(filePath)) !== source.content || getSourceContent(owner, filePath))
    throw changedSourceError();
  await writeFile(filePath, content);
}

async function planReplacement(
  source: SourceContent,
  query: string,
  replacement: string,
  options: ContentSearchOptions,
  from?: { line: number; column: number },
) {
  const result = await executeCore<{ text: string; count: number }>({
    id: crypto.randomUUID(),
    command: "workspace.replaceText",
    payload: {
      text: source.content,
      query,
      replacement,
      caseSensitive: options.caseSensitive,
      wholeWords: options.wholeWord,
      regularExpression: options.useRegex,
      from,
    },
  });
  if (!result.ok) throw new Error(result.error.message);
  return result.data;
}

export async function replaceNextInSource(
  target: ReplaceTarget,
  query: string,
  replacement: string,
  options: ContentSearchOptions,
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
): Promise<boolean> {
  const owner = replacementOwner(workspaceId);
  const source = await readSource(owner, target.filePath);
  const result = await planReplacement(source, query, replacement, options, {
    line: target.line,
    column: target.column,
  });
  if (result.count === 0 || result.text === source.content) return false;
  await writeSource(owner, target.filePath, source, result.text);
  return true;
}

export async function replaceAllInSources(
  filePaths: string[],
  query: string,
  replacement: string,
  options: ContentSearchOptions,
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
): Promise<number> {
  const owner = replacementOwner(workspaceId);
  const openSources = getOpenSourceContentByPath(owner, filePaths);
  let nextFileIndex = 0;
  let totalReplacements = 0;
  let failure: unknown;
  const replaceWorker = async () => {
    while (failure === undefined && nextFileIndex < filePaths.length) {
      const filePath = filePaths[nextFileIndex++];
      if (!filePath) continue;
      try {
        const source = await readSource(owner, filePath, openSources);
        const result = await planReplacement(source, query, replacement, options);
        if (failure !== undefined) return;
        if (result.count > 0 && result.text !== source.content) {
          await writeSource(owner, filePath, source, result.text);
          totalReplacements += result.count;
        }
      } catch (error) {
        failure ??= error ?? changedSourceError();
      }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(REPLACE_ALL_CONCURRENCY, filePaths.length) }, replaceWorker),
  );
  if (failure !== undefined) throw failure;
  return totalReplacements;
}
