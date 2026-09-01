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
import { GitCommitFileTree } from "./git-commit-file-tree";

type FilesLoadState = "idle" | "loading" | "ready" | "failed";

export function GitCommitInspector({
  repoPath,
  commit,
  commits,
  onOpenDiff,
  onOpenRangeDiff,
  onOpenSelectionDiff,
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
}) {
  const { t } = useTranslation();
  const [files, setFiles] = useState<GitCommitFile[]>([]);
  const [loadState, setLoadState] = useState<FilesLoadState>("idle");
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const requestIdRef = useRef(0);
  const inspectorPanelLayout = useGitLogPreferencesStore.use.inspectorPanelLayout();
  const { setInspectorPanelLayout } = useGitLogPreferencesStore.use.actions();
  const selectionDiff = useMemo(() => resolveGitCommitSelectionDiff(commits), [commits]);

  useEffect(() => {
    const requestId = ++requestIdRef.current;
    setFiles([]);
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
      setLoadState("ready");
    });

    return () => {
      requestIdRef.current += 1;
    };
  }, [repoPath, selectionDiff]);

  return (
    <div className="h-full min-h-0 bg-surface/35 font-sans ui-text-sm select-none">
      <ResizablePanelGroup
        orientation="vertical"
        defaultLayout={inspectorPanelLayout}
        onLayoutChanged={(layout, meta) => {
          if (meta.isUserInteraction) setInspectorPanelLayout(layout);
        }}
      >
        <ResizablePanel id="files" defaultSize="62" minSize={90}>
          <div className="flex h-full min-h-0 flex-col">
            <div className="flex h-8 shrink-0 items-center gap-2 border-border border-b bg-surface px-2 text-subtle-foreground">
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
                onSelect={setSelectedPath}
                onOpen={(path) => {
                  if (selectionDiff?.kind === "commit") onOpenDiff(selectionDiff.commit, path);
                  else if (selectionDiff?.kind === "range") onOpenRangeDiff(selectionDiff, path);
                  else if (selectionDiff?.kind === "selection") {
                    onOpenSelectionDiff(selectionDiff, path);
                  }
                }}
              />
            )}
          </div>
        </ResizablePanel>
        <ResizableHandle />
        <ResizablePanel id="details" defaultSize="38" minSize={80}>
          <div className="h-full overflow-auto border-border bg-background p-3">
            {commit ? (
              <div className="space-y-2 select-text">
                <div className="font-medium text-foreground">{commit.message}</div>
                {commit.description ? (
                  <div className="whitespace-pre-wrap text-subtle-foreground">
                    {commit.description}
                  </div>
                ) : null}
                <div className="font-mono text-[11px] text-subtle-foreground">
                  {commit.shortHash} · {commit.author}
                  {commit.email ? ` <${commit.email}>` : ""}
                </div>
                <div className="font-mono text-[11px] text-subtle-foreground">{commit.date}</div>
                {commit.decorations ? (
                  <div className="text-primary">{commit.decorations}</div>
                ) : null}
                <div className="break-all font-mono text-[10px] text-subtle-foreground">
                  {commit.hash}
                </div>
              </div>
            ) : (
              <div className="flex h-full items-center justify-center text-subtle-foreground">
                {t("git.log.commitDetails")}
              </div>
            )}
          </div>
        </ResizablePanel>
      </ResizablePanelGroup>
    </div>
  );
}
