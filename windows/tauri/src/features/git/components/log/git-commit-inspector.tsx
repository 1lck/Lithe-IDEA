import { useEffect, useEffectEvent, useMemo, useRef, useState } from "react";
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
  // Commit contents are immutable. A new history array or refreshed metadata
  // must not clear the file tree or restart a read for the same comparison.
  const selectionKey =
    !repoPath || !selectionDiff
      ? null
      : JSON.stringify([
          repoPath,
          selectionDiff.kind,
          selectionDiff.kind === "commit"
            ? selectionDiff.commit.hash
            : selectionDiff.kind === "range"
              ? [selectionDiff.baseRef, selectionDiff.targetRef]
              : selectionDiff.commits.map((selected) => selected.hash),
        ]);
  const [loadedSelectionKey, setLoadedSelectionKey] = useState<string | null>(null);
  // Only a failed read is retryable: successful and in-flight reads keep their stable identity.
  const [failedSelectionKey, setFailedSelectionKey] = useState<string | null>(null);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const handledPreviewRequestRef = useRef(previewRequest);

  // Selecting a commit previews its first file, like the IDEA Git log. Only explicit user
  // selections bump `previewRequest`, so opening the Log never steals the editor on its own.
  useEffect(() => {
    if (!selectionDiff || loadedSelectionKey !== selectionKey) return;
    if (handledPreviewRequestRef.current === previewRequest) return;
    handledPreviewRequestRef.current = previewRequest;

    const firstPath = getFirstCommitFilePath(files);
    if (!firstPath) return;
    setSelectedPath(firstPath);
    onPreviewFile(selectionDiff, firstPath);
  }, [files, loadedSelectionKey, onPreviewFile, previewRequest, selectionDiff, selectionKey]);

  const loadSelectionFiles = useEffectEvent(() => {
    if (!repoPath || !selectionDiff) return Promise.resolve(null);
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
        : aggregateSelectedCommitFileRows(results.map((result) => ({ files: result.files ?? [] }))),
    );
  });

  // Re-selecting the same commit or refreshing history retries a failed read. The failed key must
  // match the current selection, otherwise a stale failure would double-load a newly chosen commit.
  const retryFailedSelection = useEffectEvent(() => {
    if (failedSelectionKey !== null && failedSelectionKey === selectionKey) {
      setLoadAttempt((attempt) => attempt + 1);
    }
  });
  useEffect(() => {
    retryFailedSelection();
  }, [previewRequest, selectionDiff]);

  useEffect(() => {
    const requestId = ++requestIdRef.current;
    setFiles([]);
    setLoadedSelectionKey(null);
    setFailedSelectionKey(null);
    setSelectedPath(null);
    if (!selectionKey) {
      setLoadState("idle");
      return;
    }

    setLoadState("loading");
    void loadSelectionFiles().then((loadedFiles) => {
      if (requestId !== requestIdRef.current) return;
      if (loadedFiles === null) {
        setFailedSelectionKey(selectionKey);
        setLoadState("failed");
        return;
      }
      setFiles(loadedFiles);
      setLoadedSelectionKey(selectionKey);
      setLoadState("ready");
    });

    return () => {
      requestIdRef.current += 1;
    };
  }, [selectionKey, loadAttempt]);

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
              <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 px-4 text-center">
                <span className="text-destructive">{t("git.log.unableToLoadFiles")}</span>
                <Button
                  type="button"
                  variant="ghost"
                  size="xs"
                  onClick={() => setLoadAttempt((attempt) => attempt + 1)}
                >
                  {t("git.log.retry")}
                </Button>
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
