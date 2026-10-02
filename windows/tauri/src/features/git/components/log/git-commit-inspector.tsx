import { useEffect, useMemo, useRef, useState } from "react";
import { GitDiffIcon } from "@/ui/icons";
import { Button } from "@/ui/button";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { useTranslation } from "@/i18n/locale-provider";
import { getCommitFiles } from "../../api/git-commits-api";
import { getRefDiff } from "../../api/git-diff-api";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit, GitCommitFile } from "../../types/git.types";
import { mapGitReadsInBatches } from "../../utils/git-async-batch";
import {
  aggregateSelectedCommitFileRows,
  gitDiffsToCommitFiles,
  resolveGitCommitSelectionDiff,
  type GitCommitSelectionDiff,
} from "../../utils/git-commit-selection-diff";
import { GitCommitDetails } from "./git-commit-details";
import { GitCommitFileTree, getFirstCommitFilePath } from "./git-commit-file-tree";

type FilesLoadState = "idle" | "loading" | "ready" | "failed";

export function GitCommitInspector({
  repoPath,
  commit,
  commits,
  onOpenDiff,
  onOpenRangeDiff,
  onOpenSelectionDiff,
  onPreviewFile,
  previewRequest,
}: {
  repoPath: string | null;
  commit: GitCommit | null;
  commits: readonly GitCommit[];
  onOpenDiff: (commit: GitCommit, filePath?: string) => void;
  onOpenRangeDiff: (
    range: Extract<GitCommitSelectionDiff, { kind: "range" }>,
    filePath?: string,
  ) => void;
  onOpenSelectionDiff: (
    selection: Extract<GitCommitSelectionDiff, { kind: "selection" }>,
    filePath?: string,
  ) => void;
  /** Shows only one file's diff in the editor preview tab. */
  onPreviewFile: (selection: GitCommitSelectionDiff, filePath: string) => void;
  /** Bumped when the user selects a commit; the first file is previewed once its files load. */
  previewRequest: number;
}) {
  const { t } = useTranslation();
  const [files, setFiles] = useState<GitCommitFile[]>([]);
  const [loadState, setLoadState] = useState<FilesLoadState>("idle");
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const requestIdRef = useRef(0);
  const inspectorPanelLayout = useGitLogPreferencesStore.use.inspectorPanelLayout();
  const { setInspectorPanelLayout } = useGitLogPreferencesStore.use.actions();
  const selectionDiff = useMemo(() => resolveGitCommitSelectionDiff(commits), [commits]);
  // The selection `files` were loaded for; guards against previewing the previous commit's files
  // during the render in which a new selection has arrived but its files have not loaded yet.
  const [loadedSelection, setLoadedSelection] = useState<GitCommitSelectionDiff | null>(null);
  const handledPreviewRequestRef = useRef(previewRequest);

  // Selecting a commit previews its first file, like the IDEA Git log. Only explicit user
  // selections bump `previewRequest`, so opening the Log never steals the editor on its own.
  useEffect(() => {
    if (!selectionDiff || loadedSelection !== selectionDiff) return;
    if (handledPreviewRequestRef.current === previewRequest) return;
    handledPreviewRequestRef.current = previewRequest;

    const firstPath = getFirstCommitFilePath(files);
    if (!firstPath) return;
    setSelectedPath(firstPath);
    onPreviewFile(selectionDiff, firstPath);
  }, [files, loadedSelection, onPreviewFile, previewRequest, selectionDiff]);

  useEffect(() => {
    const requestId = ++requestIdRef.current;
    setFiles([]);
    setLoadedSelection(null);
    setSelectedPath(null);
    if (!repoPath || !selectionDiff) {
      setLoadState("idle");
      return;
    }

    setLoadState("loading");
    const filesPromise = (() => {
      if (selectionDiff.kind === "commit") {
        return getCommitFiles(repoPath, selectionDiff.commit.hash);
      }
      if (selectionDiff.kind === "range") {
        return getRefDiff(repoPath, selectionDiff.baseRef, selectionDiff.targetRef).then((diffs) =>
          diffs ? gitDiffsToCommitFiles(diffs) : null,
        );
      }
      return mapGitReadsInBatches(selectionDiff.commits, (selectedCommit) =>
        getCommitFiles(repoPath, selectedCommit.hash).then((files) => ({ files })),
      ).then((results) =>
        results.some((result) => result.files === null)
          ? null
          : aggregateSelectedCommitFileRows(
              results.map((result) => ({ files: result.files ?? [] })),
            ),
      );
    })();
    void filesPromise.then((loadedFiles) => {
      if (requestId !== requestIdRef.current) return;
      if (loadedFiles === null) {
        setLoadState("failed");
        return;
      }
      setFiles(loadedFiles);
      setLoadedSelection(selectionDiff);
      setLoadState("ready");
    });

    return () => {
      requestIdRef.current += 1;
    };
  }, [repoPath, selectionDiff]);

  return (
    <div className="h-full min-h-0 bg-background font-sans ui-text-sm select-none">
      <ResizablePanelGroup
        orientation="vertical"
        defaultLayout={inspectorPanelLayout}
        onLayoutChanged={(layout, meta) => {
          if (meta.isUserInteraction) setInspectorPanelLayout(layout);
        }}
      >
        <ResizablePanel id="files" defaultSize="62" minSize={90}>
          <div className="flex h-full min-h-0 flex-col">
            <div className="flex h-8 shrink-0 items-center gap-2 border-border border-b bg-background px-2 text-subtle-foreground">
              <span>{t("git.log.commitFiles")}</span>
              <span className="ml-auto tabular-nums">
                {loadState === "loading"
                  ? t("git.log.loadingShort")
                  : t("git.log.filesCount", { count: files.length })}
              </span>
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                disabled={!selectionDiff}
                onClick={() => {
                  if (selectionDiff?.kind === "commit") onOpenDiff(selectionDiff.commit);
                  else if (selectionDiff?.kind === "range") onOpenRangeDiff(selectionDiff);
                  else if (selectionDiff?.kind === "selection") {
                    onOpenSelectionDiff(selectionDiff);
                  }
                }}
                tooltip={t("git.log.openCommitDiff")}
                aria-label={t("git.log.openCommitDiff")}
              >
                <GitDiffIcon />
              </Button>
            </div>
            {!commit ? (
              <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
                {t("git.log.selectCommit")}
              </div>
            ) : loadState === "loading" ? (
              <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
                {t("git.log.loadingChangedFiles")}
              </div>
            ) : loadState === "failed" ? (
              <div className="flex min-h-0 flex-1 items-center justify-center px-4 text-center text-destructive">
                {t("git.log.unableToLoadFiles")}
              </div>
            ) : files.length === 0 ? (
              <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
                {t("git.log.noChangedFiles")}
              </div>
            ) : (
              <GitCommitFileTree
                files={files}
                selectedPath={selectedPath}
                onSelect={(path) => {
                  setSelectedPath(path);
                  if (selectionDiff) onPreviewFile(selectionDiff, path);
                }}
                onOpen={(path) => {
                  if (selectionDiff) onPreviewFile(selectionDiff, path);
                }}
              />
            )}
          </div>
        </ResizablePanel>
        <ResizableHandle />
        <ResizablePanel id="details" defaultSize="38" minSize={80}>
          <div className="h-full overflow-auto border-border bg-background p-3">
            <GitCommitDetails repoPath={repoPath} commit={commit} />
          </div>
        </ResizablePanel>
      </ResizablePanelGroup>
    </div>
  );
}
