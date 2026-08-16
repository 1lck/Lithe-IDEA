import { useEffect, useRef, useState } from "react";
import { GitDiffIcon } from "@/ui/icons";
import { Button } from "@/ui/button";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { getCommitFiles } from "../../api/git-commits-api";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitCommit, GitCommitFile } from "../../types/git.types";
import { GitCommitFileTree } from "./git-commit-file-tree";

type FilesLoadState = "idle" | "loading" | "ready" | "failed";

export function GitCommitInspector({
  repoPath,
  commit,
  onOpenDiff,
}: {
  repoPath: string | null;
  commit: GitCommit | null;
  onOpenDiff: (commit: GitCommit, filePath?: string) => void;
}) {
  const [files, setFiles] = useState<GitCommitFile[]>([]);
  const [loadState, setLoadState] = useState<FilesLoadState>("idle");
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const requestIdRef = useRef(0);
  const inspectorPanelLayout = useGitLogPreferencesStore.use.inspectorPanelLayout();
  const { setInspectorPanelLayout } = useGitLogPreferencesStore.use.actions();

  useEffect(() => {
    const requestId = ++requestIdRef.current;
    setFiles([]);
    setSelectedPath(null);
    if (!repoPath || !commit) {
      setLoadState("idle");
      return;
    }

    setLoadState("loading");
    void getCommitFiles(repoPath, commit.hash).then((result) => {
      if (requestId !== requestIdRef.current) return;
      if (!result) {
        setLoadState("failed");
        return;
      }
      setFiles(result);
      setLoadState("ready");
    });

    return () => {
      requestIdRef.current += 1;
    };
  }, [commit, repoPath]);

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
              <span>Commit files</span>
              <span className="ml-auto tabular-nums">
                {loadState === "loading" ? "Loading…" : `${files.length} files`}
              </span>
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                disabled={!commit}
                onClick={() => commit && onOpenDiff(commit)}
                tooltip="Open commit diff"
                aria-label="Open commit diff"
              >
                <GitDiffIcon />
              </Button>
            </div>
            {!commit ? (
              <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
                Select a commit
              </div>
            ) : loadState === "loading" ? (
              <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
                Loading changed files…
              </div>
            ) : loadState === "failed" ? (
              <div className="flex min-h-0 flex-1 items-center justify-center px-4 text-center text-destructive">
                Unable to load changed files
              </div>
            ) : files.length === 0 ? (
              <div className="flex min-h-0 flex-1 items-center justify-center text-subtle-foreground">
                No changed files
              </div>
            ) : (
              <GitCommitFileTree
                files={files}
                selectedPath={selectedPath}
                onSelect={setSelectedPath}
                onOpen={(path) => onOpenDiff(commit, path)}
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
                Commit details
              </div>
            )}
          </div>
        </ResizablePanel>
      </ResizablePanelGroup>
    </div>
  );
}
