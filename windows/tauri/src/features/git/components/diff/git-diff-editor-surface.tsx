import type { BreadcrumbProps } from "@/features/editor/components/toolbar/breadcrumb";
import type { MultiFileDiff } from "../../types/git-diff.types";
import type { GitDiff } from "../../types/git.types";
import MonacoGitDiff from "./monaco-git-diff";
import GitDiffEditorStack from "./git-diff-editor-stack";

interface GitDiffEditorSurfaceProps {
  cacheKey: string;
  diff?: GitDiff;
  multiDiff?: MultiFileDiff;
  title?: string;
  breadcrumbProps?: BreadcrumbProps;
  readOnly?: boolean;
}

export default function GitDiffEditorSurface({ diff, multiDiff, title }: GitDiffEditorSurfaceProps) {
  if (multiDiff) return <GitDiffEditorStack multiDiff={multiDiff} />;
  if (!diff) return null;
  return <div className="flex min-h-0 flex-1 flex-col overflow-hidden bg-background">
    <div className="border-border border-b px-3 py-2 text-xs text-text-lighter">
      {title || diff.new_path || diff.old_path || diff.file_path}
    </div>
    <div className="min-h-0 flex-1">
      <MonacoGitDiff diff={diff} viewMode={diff.is_new || diff.is_deleted ? "unified" : "split"} />
    </div>
  </div>;
}
