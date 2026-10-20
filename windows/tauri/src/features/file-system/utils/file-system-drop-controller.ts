import { parseDroppedPaths } from "./file-system-dropped-paths";

export const TERMINAL_FILE_DROP_EVENT = "lithe-terminal-file-drop";
/**
 * Dispatched on the Agent composer for files dropped from the OS or the project
 * tree. WebView2 delivers OS drops only as native Tauri events, and the project
 * tree drags with mouse events, so neither reaches an HTML5 `drop` handler.
 */
export const AGENT_FILE_DROP_EVENT = "lithe-agent-file-drop";
/**
 * Dispatched on the Agent composer while a drag is over it. OS drops and
 * project-tree drags never reach an HTML5 `dragenter`, so the drop point needs
 * this signal to highlight the same way the macOS composer does.
 */
export const AGENT_FILE_DROP_HOVER_EVENT = "lithe-agent-file-drop-hover";

export interface TerminalFileDropDetail {
  paths: string[];
}

export type AgentFileDropDetail = TerminalFileDropDetail;

export interface AgentFileDropHoverDetail {
  active: boolean;
}

/**
 * In-app drops send absolute paths, because only the target terminal knows the
 * directory its shell is in and therefore how to relativize them.
 */
export const TERMINAL_PATH_INSERT_EVENT = "lithe-terminal-path-insert";

export interface TerminalPathInsertDetail {
  paths: string[];
}

export function resolveDropClientPoint(
  position: { x: number; y: number },
  scaleFactor: number,
  elementFromPoint: (x: number, y: number) => Element | null,
) {
  const effectiveScaleFactor = Number.isFinite(scaleFactor) && scaleFactor > 0 ? scaleFactor : 1;
  const logicalPoint = {
    x: position.x / effectiveScaleFactor,
    y: position.y / effectiveScaleFactor,
  };
  const logicalElement = elementFromPoint(logicalPoint.x, logicalPoint.y);

  if (logicalElement || effectiveScaleFactor === 1) {
    return { point: logicalPoint, element: logicalElement };
  }

  const rawPoint = { x: position.x, y: position.y };
  return {
    point: rawPoint,
    element: elementFromPoint(rawPoint.x, rawPoint.y),
  };
}

export interface ExternalFileDropPayload {
  type: string;
  paths?: string[];
  position?: { x: number; y: number };
}

export interface ExternalFileDropController {
  onDrop: (paths: string[]) => void | Promise<void>;
  setDraggingOver: (isDraggingOver: boolean) => void;
  onError?: (error: unknown) => void;
}

export async function handleDroppedExternalPaths(
  rawPaths: string[],
  onDrop: (paths: string[]) => void | Promise<void>,
  onError?: (error: unknown) => void,
) {
  const paths = parseDroppedPaths(rawPaths);
  if (paths.length === 0) return;

  try {
    await onDrop(paths);
  } catch (error) {
    onError?.(error);
  }
}

export async function handleExternalFileDropPayload(
  payload: ExternalFileDropPayload,
  controller: ExternalFileDropController,
) {
  if (payload.type === "drop" && "paths" in payload) {
    await handleDroppedExternalPaths(payload.paths || [], controller.onDrop, controller.onError);
    controller.setDraggingOver(false);
    return true;
  }

  if (payload.type === "enter") {
    controller.setDraggingOver(true);
    return true;
  }

  if (payload.type === "leave") {
    controller.setDraggingOver(false);
    return true;
  }

  return false;
}

export function isExternalFileDragTypeList(types: Iterable<string> | null | undefined): boolean {
  if (!types) return false;
  return Array.from(types).includes("Files");
}

export type ExternalFileDropRoute = "global" | "local" | "terminal" | "agent";

const TERMINAL_DROP_TARGET_SELECTOR = "[data-terminal-drop-target]";
export const AGENT_DROP_TARGET_SELECTOR = "[data-agent-file-drop-target]";
const LOCAL_DROP_TARGET_SELECTOR = [
  "[data-external-file-drop-scope]",
  "[data-bottom-pane-drop-target]",
  "[data-ai-context-drop-target]",
].join(",");
const PANE_DROP_TARGET_SELECTOR = "[data-pane-container]";

/**
 * Whether the point is inside a terminal, which accepts dropped paths directly.
 * The explorer uses this before its pane handling, because a terminal lives
 * inside a pane container and would otherwise open the file instead.
 */
export function isTerminalDropTarget(target: Element | null | undefined): boolean {
  return Boolean(target?.closest(TERMINAL_DROP_TARGET_SELECTOR));
}

/**
 * Insert explorer paths into the terminal at `target`.
 * Returns false when the target is not a terminal or there is nothing to insert.
 */
export function dispatchTerminalPathInsert(
  target: Element | null | undefined,
  paths: readonly string[],
): boolean {
  const terminalTarget = target?.closest<HTMLElement>(TERMINAL_DROP_TARGET_SELECTOR);
  if (!terminalTarget || paths.length === 0) return false;

  terminalTarget.dispatchEvent(
    new CustomEvent<TerminalPathInsertDetail>(TERMINAL_PATH_INSERT_EVENT, {
      detail: { paths: [...paths] },
    }),
  );
  return true;
}

export function dispatchDroppedPathsToTerminal(
  target: Pick<Element, "closest"> | null | undefined,
  rawPaths: string[],
): boolean {
  const terminalTarget = target?.closest<HTMLElement>(TERMINAL_DROP_TARGET_SELECTOR);
  const paths = parseDroppedPaths(rawPaths);
  if (!terminalTarget || paths.length === 0) return false;

  terminalTarget.dispatchEvent(
    new CustomEvent<TerminalFileDropDetail>(TERMINAL_FILE_DROP_EVENT, {
      detail: { paths },
    }),
  );
  return true;
}

/** Hand dropped paths to the Agent composer under `target`, if there is one. */
export function dispatchDroppedPathsToAgent(
  target: Pick<Element, "closest"> | null | undefined,
  rawPaths: string[],
): boolean {
  const agentTarget = target?.closest<HTMLElement>(AGENT_DROP_TARGET_SELECTOR);
  const paths = parseDroppedPaths(rawPaths);
  if (!agentTarget || paths.length === 0) return false;

  agentTarget.dispatchEvent(
    new CustomEvent<AgentFileDropDetail>(AGENT_FILE_DROP_EVENT, {
      detail: { paths },
    }),
  );
  return true;
}

/** Tell the Agent composer under `target` whether a drag is over it. */
export function dispatchAgentDropHover(
  target: Pick<Element, "closest"> | null | undefined,
  active: boolean,
): boolean {
  const agentTarget = target?.closest<HTMLElement>(AGENT_DROP_TARGET_SELECTOR);
  if (!agentTarget) return false;

  agentTarget.dispatchEvent(
    new CustomEvent<AgentFileDropHoverDetail>(AGENT_FILE_DROP_HOVER_EVENT, {
      detail: { active },
    }),
  );
  return true;
}

export function getExternalFileDropRoute(
  target: Pick<Element, "closest"> | null | undefined,
  treatPaneDropAsGlobal = false,
): ExternalFileDropRoute {
  if (!target) return "global";
  if (target.closest(TERMINAL_DROP_TARGET_SELECTOR)) return "terminal";
  if (target.closest(AGENT_DROP_TARGET_SELECTOR)) return "agent";
  if (target.closest(LOCAL_DROP_TARGET_SELECTOR)) return "local";
  if (target.closest(PANE_DROP_TARGET_SELECTOR)) {
    return treatPaneDropAsGlobal ? "global" : "local";
  }
  return "global";
}
