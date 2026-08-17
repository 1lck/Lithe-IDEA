import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/ui/button";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { useTranslation } from "@/i18n/locale-provider";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useGitLogController } from "../../hooks/use-git-log-controller";
import { useGitDiffActions } from "../../hooks/use-git-diff-actions";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import { useRepositoryStore } from "../../stores/git-repository.store";
import type { GitCommit, GitFile } from "../../types/git.types";
import type {
  WorkingTreeDiffEntry,
  WorkingTreeDiffScope,
} from "../../services/working-tree-diff-loader";
import { GitCommitInspector } from "./git-commit-inspector";
import { GitCommitTable } from "./git-commit-table";
import { GitLogTitleBar } from "./git-log-title-bar";
import { GitReferenceTree } from "./git-reference-tree";

export function GitLogToolWindow() {
  const { t } = useTranslation();
  const activeRepoPath = useRepositoryStore.use.activeRepoPath();
  const rootFolderPath = useProjectStore((state) => state.rootFolderPath);
  const repoPath = activeRepoPath ?? rootFolderPath ?? null;
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const {
    history,
    loadState,
    error,
    selectedReference,
    isLoadingMore,
    selectReference,
    refresh,
    loadMore,
  } = useGitLogController(repoPath);
  const [selectedCommit, setSelectedCommit] = useState<GitCommit | null>(null);
  const mainPanelLayout = useGitLogPreferencesStore.use.mainPanelLayout();
  const { setMainPanelLayout } = useGitLogPreferencesStore.use.actions();
  const currentReference = useMemo(
    () => history.references.find((reference) => reference.isCurrent) ?? null,
    [history.references],
  );
  const commitByHash = useMemo(
    () => new Map(history.commits.map((commit) => [commit.hash, commit] as const)),
    [history.commits],
  );
  const emptyWorkingTreeEntries = useMemo<Record<WorkingTreeDiffScope, WorkingTreeDiffEntry[]>>(
    () => ({
      all: [],
      staged: [],
      unstaged: [],
    }),
    [],
  );
  const emptyGitFileByPath = useMemo(() => new Map<string, GitFile>(), []);
  const { isLoadingCommitDiff, isLoadingBranchDiff, viewCommitDiff, viewBranchDiff } =
    useGitDiffActions({
      activeRepoPath: repoPath,
      gitFileByPath: emptyGitFileByPath,
      workingTreeDiffEntriesByScope: emptyWorkingTreeEntries,
      commitByHash,
      currentBranch: currentReference?.shortName,
    });

  useEffect(() => {
    setSelectedCommit((current) => {
      if (current && commitByHash.has(current.hash)) return commitByHash.get(current.hash) ?? null;
      return history.commits[0] ?? null;
    });
  }, [commitByHash, history.commits]);

  const openDiff = (commit: GitCommit, filePath?: string) => {
    if (isLoadingCommitDiff) return;
    void viewCommitDiff(commit.hash, filePath);
  };

  const copyCommitText = async (text: string, label: string) => {
    if (await tryWriteClipboardText(text)) {
      toast.success(t("git.log.copied", { label }));
      return;
    }
    toast.error(t("git.log.copyFailed", { label: label.toLocaleLowerCase() }));
  };

  const comparisonBaseRef =
    selectedReference && !selectedReference.isCurrent
      ? selectedReference.fullName
      : selectedCommit?.hash;

  return (
    <div className="flex h-full min-h-0 flex-col overflow-hidden bg-background text-foreground">
      <GitLogTitleBar
        referenceName={selectedReference?.shortName ?? t("git.log.all")}
        isRefreshing={loadState === "loading"}
        isOpeningDiff={isLoadingCommitDiff}
        isComparing={isLoadingBranchDiff}
        hasSelectedCommit={selectedCommit !== null}
        canCompareWithHead={Boolean(comparisonBaseRef)}
        onShowAll={() => {
          setSelectedCommit(null);
          selectReference(null);
        }}
        onRefresh={() => void refresh()}
        onOpenDiff={() => {
          if (selectedCommit) openDiff(selectedCommit);
        }}
        onCompareWithHead={() => {
          if (comparisonBaseRef) void viewBranchDiff(comparisonBaseRef);
        }}
        onCopyHash={() => {
          if (selectedCommit) void copyCommitText(selectedCommit.hash, t("git.log.commitHash"));
        }}
        onClose={() => setIsBottomPaneVisible(false)}
      />

      {loadState === "failed" && history.commits.length > 0 ? (
        <div className="flex h-7 shrink-0 items-center gap-2 border-destructive/30 border-b bg-destructive/10 px-2 font-sans ui-text-sm text-destructive">
          <span className="min-w-0 flex-1 truncate">{error ?? t("git.log.unableToRefresh")}</span>
          <button
            type="button"
            className="font-medium hover:underline"
            onClick={() => void refresh()}
          >
            {t("git.log.retry")}
          </button>
        </div>
      ) : null}

      {!repoPath ? (
        <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 text-subtle-foreground">
          <div className="font-medium text-foreground">{t("git.log.noRepository")}</div>
          <div>{t("git.log.openWorkspace")}</div>
        </div>
      ) : loadState === "loading" && history.commits.length === 0 ? (
        <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
          {t("git.log.loading")}
        </div>
      ) : loadState === "failed" && history.commits.length === 0 ? (
        <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 px-6 text-center">
          <div className="text-destructive">{error ?? t("git.log.unableToLoad")}</div>
          <Button type="button" variant="ghost" size="xs" onClick={() => void refresh()}>
            {t("git.log.tryAgain")}
          </Button>
        </div>
      ) : (
        <ResizablePanelGroup
          orientation="horizontal"
          className="min-h-0 flex-1"
          defaultLayout={mainPanelLayout}
          onLayoutChanged={(layout, meta) => {
            if (meta.isUserInteraction) setMainPanelLayout(layout);
          }}
        >
          <ResizablePanel id="references" defaultSize="19" minSize={140}>
            <GitReferenceTree
              references={history.references}
              selectedReference={selectedReference}
              onSelect={(reference) => {
                setSelectedCommit(null);
                selectReference(reference);
              }}
            />
          </ResizablePanel>
          <ResizableHandle />
          <ResizablePanel id="commits" defaultSize="57" minSize={320}>
            <GitCommitTable
              commits={history.commits}
              selectedCommit={selectedCommit}
              hasMore={history.hasMore}
              isLoadingMore={isLoadingMore}
              onSelect={setSelectedCommit}
              onOpenDiff={(commit) => openDiff(commit)}
              onCompareWithHead={(commit) => void viewBranchDiff(commit.hash)}
              onCopyHash={(commit) => void copyCommitText(commit.hash, t("git.log.commitHash"))}
              onCopyMessage={(commit) =>
                void copyCommitText(
                  [commit.message, commit.description].filter(Boolean).join("\n\n"),
                  t("git.log.commitMessage"),
                )
              }
              onLoadMore={() => void loadMore()}
            />
          </ResizablePanel>
          <ResizableHandle />
          <ResizablePanel id="inspector" defaultSize="24" minSize={220}>
            <GitCommitInspector repoPath={repoPath} commit={selectedCommit} onOpenDiff={openDiff} />
          </ResizablePanel>
        </ResizablePanelGroup>
      )}
    </div>
  );
}
