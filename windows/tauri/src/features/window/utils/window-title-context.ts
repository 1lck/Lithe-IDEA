import type { PaneContent } from "@/features/panes/types/pane-content.types";
import type { PaneNode } from "@/features/panes/types/pane.types";
import { findPaneGroup } from "@/features/panes/utils/pane-tree";
import {
  WELCOME_WORKSPACE_ID,
  type WorkspaceRuntimeStatus,
} from "@/features/workspace/types/workspace-runtime.types";
import type { ProjectTab } from "../stores/workspace-tabs.store";
import { getProjectDisplayLabel } from "./project-display-label";

export interface WindowTitleContext {
  projects: Array<{ workspaceId: string; displayName: string; path: string }>;
  activeWorkspaceId: string | null;
  fileName: string | null;
}

export type WindowTitleProject = Pick<ProjectTab, "id" | "name" | "path" | "displayAlias">;

export interface WindowTitlePaneState {
  root: PaneNode;
  bottomRoot: PaneNode;
  activePaneId: string;
}

export interface WindowTitleBufferState {
  buffers: readonly PaneContent[];
}

interface WindowTitleSnapshot {
  projects: readonly WindowTitleProject[];
  workspaceId: string;
  status: WorkspaceRuntimeStatus | undefined;
  panes?: WindowTitlePaneState;
  buffers?: WindowTitleBufferState;
}

function localFileName(path: string): string | null {
  const normalized = path.replace(/\\/g, "/");
  if (!/^(?:[A-Za-z]:\/|\/)/.test(normalized)) return null;
  if (/^\/\/(?:wsl\$|wsl\.localhost)\//i.test(normalized)) return null;
  return normalized.split("/").pop() || null;
}

export function getWindowTitleFileName(buffer: PaneContent | undefined): string | null {
  if (!buffer) return null;

  switch (buffer.type) {
    case "markdownPreview":
    case "htmlPreview":
    case "csvPreview":
      return localFileName(buffer.sourceFilePath);
    case "editor":
      if (buffer.isVirtual) return null;
      return localFileName(buffer.path) ? buffer.name || localFileName(buffer.path) : null;
    case "image":
    case "pdf":
    case "binary":
      return localFileName(buffer.path) ? buffer.name || localFileName(buffer.path) : null;
    default:
      return null;
  }
}

export function buildWindowTitleContext(snapshot: WindowTitleSnapshot): WindowTitleContext {
  const projects = snapshot.projects
    .map((project) => ({
      workspaceId: project.id,
      displayName: getProjectDisplayLabel(project),
      path: project.path,
    }))
    .sort((left, right) => left.workspaceId.localeCompare(right.workspaceId));
  const activeWorkspaceId = projects.some((project) => project.workspaceId === snapshot.workspaceId)
    ? snapshot.workspaceId
    : null;
  const context: WindowTitleContext = { projects, activeWorkspaceId, fileName: null };

  // 加载期间只显示项目名，欢迎工作区则允许独立文件使用自身名称。
  if (
    (snapshot.status !== "ready" && snapshot.status !== "empty") ||
    (!activeWorkspaceId && snapshot.workspaceId !== WELCOME_WORKSPACE_ID) ||
    !snapshot.panes ||
    !snapshot.buffers
  ) {
    return context;
  }

  const pane =
    findPaneGroup(snapshot.panes.root, snapshot.panes.activePaneId) ??
    findPaneGroup(snapshot.panes.bottomRoot, snapshot.panes.activePaneId);
  const buffer = snapshot.buffers.buffers.find((entry) => entry.id === pane?.activeBufferId);
  context.fileName = getWindowTitleFileName(buffer);
  return context;
}
