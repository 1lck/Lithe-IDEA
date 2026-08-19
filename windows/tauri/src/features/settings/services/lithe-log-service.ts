import { invoke } from "@/platform/tauri-core";
import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { usePaneStore } from "@/features/panes/stores/pane.store";
import type { EditorContent } from "@/features/panes/types/pane-content.types";

interface LitheLogFile {
  path: string;
  content: string;
  targetLine: number;
  truncated: boolean;
}

interface LitheLogFileResponse {
  path: string;
  content: string;
  target_line: number;
  truncated: boolean;
}

function toLitheLogFile(response: LitheLogFileResponse): LitheLogFile {
  return {
    path: response.path,
    content: response.content,
    targetLine: Math.max(0, response.target_line - 1),
    truncated: response.truncated,
  };
}

function getFileName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? "Lithe.log";
}

function getLineStartOffset(content: string, targetLine: number): number {
  if (targetLine <= 0) return 0;

  let line = 0;
  let offset = 0;
  while (line < targetLine) {
    const nextNewline = content.indexOf("\n", offset);
    if (nextNewline === -1) return content.length;
    offset = nextNewline + 1;
    line++;
  }

  return offset;
}

function cacheLogViewState(bufferId: string, content: string, targetLine: number) {
  const line = Math.max(0, targetLine);
  const offset = getLineStartOffset(content, line);
  const cursor = { line, column: 0, offset };
  const scrollTop = Math.max(0, (line - 8) * EDITOR_CONSTANTS.DEFAULT_LINE_HEIGHT);

  const viewState = {
    cursor,
    selection: undefined,
    scrollTop,
    scrollLeft: 0,
  };
  const editorActions = useEditorStateStore.getState().actions;
  editorActions.cacheViewStateForBuffer(bufferId, viewState);

  const activePane = usePaneStore.getState().actions.getActivePane();
  if (activePane) {
    editorActions.cacheViewStateForBuffer(`${activePane.id}:${bufferId}`, viewState);
  }
}

function isLitheLogBuffer(buffer: unknown): buffer is EditorContent {
  if (!buffer || typeof buffer !== "object") return false;
  const candidate = buffer as Partial<EditorContent>;
  return (
    candidate.type === "editor" &&
    candidate.isVirtual === true &&
    candidate.readOnly === true &&
    candidate.language === "log" &&
    typeof candidate.name === "string" &&
    candidate.name.toLowerCase().startsWith("lithe.") &&
    candidate.name.toLowerCase().endsWith(".log")
  );
}

function updateLogBuffer(buffer: EditorContent, logFile: LitheLogFile) {
  useBufferStore.getState().actions.updateBuffer({
    ...buffer,
    path: logFile.path,
    name: getFileName(logFile.path),
    content: logFile.content,
    savedContent: logFile.content,
    isDirty: false,
    isVirtual: true,
    readOnly: true,
    language: "log",
    tokens: [],
  });
  cacheLogViewState(buffer.id, logFile.content, logFile.targetLine);
}

async function readCurrentLitheLog() {
  return toLitheLogFile(await invoke<LitheLogFileResponse>("read_lithe_log"));
}

export async function refreshOpenLitheLogBuffer() {
  const bufferStore = useBufferStore.getState();
  const openLogBuffers = bufferStore.buffers.filter(isLitheLogBuffer);
  if (openLogBuffers.length === 0) return false;

  const target =
    openLogBuffers.find((buffer) => buffer.id === bufferStore.activeBufferId) ?? openLogBuffers[0];
  const logFile = await readCurrentLitheLog();
  updateLogBuffer(target, logFile);
  for (const duplicate of openLogBuffers) {
    if (duplicate.id !== target.id) {
      useBufferStore.getState().actions.closeBufferForce(duplicate.id);
    }
  }
  return true;
}

export async function openLitheLogBuffer() {
  const logFile = await readCurrentLitheLog();
  const currentStore = useBufferStore.getState();
  const existingLogBuffers = currentStore.buffers.filter(isLitheLogBuffer);
  const existing =
    existingLogBuffers.find((buffer) => buffer.id === currentStore.activeBufferId) ??
    existingLogBuffers[0];
  if (existing) {
    updateLogBuffer(existing, logFile);
    for (const duplicate of existingLogBuffers) {
      if (duplicate.id !== existing.id) currentStore.actions.closeBufferForce(duplicate.id);
    }
  }

  const bufferId = useBufferStore.getState().actions.openContent({
    type: "editor",
    path: logFile.path,
    name: getFileName(logFile.path),
    content: logFile.content,
    isVirtual: true,
    readOnly: true,
    language: "log",
  });

  const nextBufferStore = useBufferStore.getState();
  const openedBuffer = nextBufferStore.buffers.find((buffer) => buffer.id === bufferId);
  if (openedBuffer?.type === "editor") updateLogBuffer(openedBuffer, logFile);
  return logFile;
}
