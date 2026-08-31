import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  ArrowRightIcon as ArrowRight,
  CaretDownIcon as CaretDown,
  GitCommitIcon,
  QuestionIcon as Question,
  WarningCircleIcon as WarningCircle,
} from "@/ui/icons";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ButtonGroup, ButtonGroupSeparator } from "@/ui/button-group";
import { Checkbox } from "@/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/ui/dropdown-menu";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import { getBaseName } from "@/utils/path-helpers";
import { cn } from "@/utils/cn";
import { getCommitFiles } from "../api/git-commits-api";
import { executeGitPush, getGitPushPreview } from "../api/git-push-api";
import {
  attachGitPushDialogHost,
  type GitPushDialogRequest,
} from "../services/git-push-dialog-service";
import type { GitCommit, GitCommitFile, GitPushPreview, GitPushTagScope } from "../types/git.types";
import { GitCommitFileTree } from "./log/git-commit-file-tree";

type LoadState = "loading" | "ready" | "failed";

function StateMessage({ children, danger = false }: { children: ReactNode; danger?: boolean }) {
  return (
    <div
      className={cn(
        "flex min-h-0 flex-1 items-center justify-center px-6 text-center ui-text-sm",
        danger ? "text-destructive" : "text-subtle-foreground",
      )}
    >
      {children}
    </div>
  );
}

function CommitRow({
  commit,
  selected,
  onSelect,
}: {
  commit: GitCommit;
  selected: boolean;
  onSelect: () => void;
}) {
  const initials = commit.author.trim().slice(0, 1).toUpperCase() || "?";
  return (
    <button
      type="button"
      className={cn(
        "flex h-12 w-full min-w-0 items-center gap-2 border-border/60 border-b px-3 text-left",
        "hover:bg-accent/70 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-primary/30",
        selected && "bg-selected/80",
      )}
      onClick={onSelect}
    >
      <span className="grid size-6 shrink-0 place-items-center rounded-full bg-accent font-medium ui-text-xs text-foreground">
        {initials}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate ui-text-sm text-foreground">{commit.message}</span>
        <span className="mt-0.5 flex min-w-0 items-center gap-1.5 ui-text-xs text-subtle-foreground">
          <GitCommitIcon className="size-3 shrink-0" />
          <span className="shrink-0 font-mono">{commit.shortHash}</span>
          <span className="truncate">{commit.author}</span>
          <span className="ml-auto shrink-0">{commit.date}</span>
        </span>
      </span>
    </button>
  );
}

function GitPushDialog({
  request,
  onComplete,
}: {
  request: GitPushDialogRequest;
  onComplete: (pushed: boolean) => void;
}) {
  const { t } = useTranslation();
  const [loadState, setLoadState] = useState<LoadState>("loading");
  const [preview, setPreview] = useState<GitPushPreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [selectedCommitHash, setSelectedCommitHash] = useState<string | null>(null);
  const [files, setFiles] = useState<GitCommitFile[]>([]);
  const [filesLoading, setFilesLoading] = useState(false);
  const [filesFailed, setFilesFailed] = useState(false);
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [pushTags, setPushTags] = useState(false);
  const [tagScope, setTagScope] = useState<Exclude<GitPushTagScope, "none">>("all");
  const [isPushing, setIsPushing] = useState(false);
  const [pushError, setPushError] = useState<string | null>(null);

  const loadPreview = useCallback(async () => {
    setLoadState("loading");
    setPreviewError(null);
    setPushError(null);
    try {
      const nextPreview = await getGitPushPreview(request.repoPath, request.reference);
      setPreview(nextPreview);
      setSelectedCommitHash(nextPreview.commits[0]?.hash ?? null);
      setLoadState("ready");
    } catch (error) {
      setPreview(null);
      setSelectedCommitHash(null);
      setPreviewError(error instanceof Error ? error.message : String(error));
      setLoadState("failed");
    }
  }, [request.reference, request.repoPath]);

  useEffect(() => {
    void loadPreview();
  }, [loadPreview]);

  useEffect(() => {
    let cancelled = false;
    setSelectedPath(null);
    setFiles([]);
    setFilesFailed(false);
    if (!selectedCommitHash) {
      setFilesLoading(false);
      return () => {
        cancelled = true;
      };
    }
    setFilesLoading(true);
    void getCommitFiles(request.repoPath, selectedCommitHash).then((nextFiles) => {
      if (cancelled) return;
      setFilesLoading(false);
      if (nextFiles === null) {
        setFilesFailed(true);
        return;
      }
      setFiles(nextFiles);
    });
    return () => {
      cancelled = true;
    };
  }, [request.repoPath, selectedCommitHash]);

  const selectedCommit = useMemo(
    () => preview?.commits.find((commit) => commit.hash === selectedCommitHash) ?? null,
    [preview?.commits, selectedCommitHash],
  );
  const canPush = Boolean(preview && (preview.commits.length > 0 || pushTags));
  const tagOptions = [
    { value: "all", label: t("git.pushDialog.tagsAll") },
    { value: "reachable", label: t("git.pushDialog.tagsReachable") },
  ];

  const performPush = async (force: boolean) => {
    if (!canPush || isPushing) return;
    setIsPushing(true);
    setPushError(null);
    try {
      await executeGitPush(request.repoPath, {
        reference: request.reference,
        force,
        pushTags: pushTags ? tagScope : "none",
      });
      toast.success(t("git.pushedChanges"));
      onComplete(true);
    } catch (error) {
      const message = error instanceof Error ? error.message : t("git.pushFailed");
      setPushError(message);
      toast.error(message);
      void loadPreview();
    } finally {
      setIsPushing(false);
    }
  };

  const projectName = getBaseName(request.repoPath, t("git.repository"));

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !isPushing) onComplete(false);
      }}
    >
      <DialogContent
        size="lg"
        className="h-[min(610px,calc(100vh-2rem))] w-[min(900px,calc(100vw-2rem))] max-w-none gap-0 rounded-lg p-0"
      >
        <DialogHeader className="h-12 shrink-0 justify-center border-border/70 border-b px-4 pt-0">
          <DialogTitle>{t("git.pushDialog.title", { repository: projectName })}</DialogTitle>
          <DialogDescription className="sr-only">
            {t("git.pushDialog.description")}
          </DialogDescription>
        </DialogHeader>

        <div className="flex min-h-0 flex-1 flex-col">
          {loadState === "loading" ? (
            <StateMessage>
              <span className="flex items-center gap-2">
                <Spinner label={t("git.pushDialog.loading")} compact />
                {t("git.pushDialog.loading")}
              </span>
            </StateMessage>
          ) : loadState === "failed" ? (
            <StateMessage danger>
              <span className="flex max-w-md flex-col items-center gap-3">
                <WarningCircle className="size-5" />
                <span>{previewError || t("git.pushDialog.previewFailed")}</span>
                <Button size="sm" onClick={() => void loadPreview()}>
                  {t("git.log.retry")}
                </Button>
              </span>
            </StateMessage>
          ) : preview ? (
            <>
              <div className="flex h-9 shrink-0 min-w-0 items-center gap-2 border-border/70 border-b bg-surface/45 px-3 ui-text-sm">
                <span className="min-w-0 truncate font-medium">{preview.localBranch}</span>
                <ArrowRight className="size-3.5 shrink-0 text-subtle-foreground" />
                <span className="min-w-0 truncate text-primary">
                  {preview.remote}/{preview.remoteBranch}
                </span>
                {!preview.upstream ? (
                  <span className="ml-auto shrink-0 text-subtle-foreground">
                    {t("git.pushDialog.newUpstream")}
                  </span>
                ) : null}
              </div>

              <div className="grid min-h-0 flex-1 grid-cols-[minmax(260px,44%)_minmax(0,1fr)] max-sm:grid-cols-1 max-sm:grid-rows-2">
                <section className="flex min-h-0 flex-col border-border/70 border-r max-sm:border-r-0 max-sm:border-b">
                  <div className="flex h-8 shrink-0 items-center border-border/70 border-b px-3 font-medium ui-text-sm">
                    {t("git.pushDialog.commitHistory")}
                    <span className="ml-auto text-subtle-foreground tabular-nums">
                      {preview.commits.length}
                    </span>
                  </div>
                  {preview.commits.length === 0 ? (
                    <StateMessage>{t("git.pushDialog.noCommits")}</StateMessage>
                  ) : (
                    <div className="min-h-0 flex-1 overflow-auto">
                      {preview.commits.map((commit) => (
                        <CommitRow
                          key={commit.hash}
                          commit={commit}
                          selected={commit.hash === selectedCommitHash}
                          onSelect={() => setSelectedCommitHash(commit.hash)}
                        />
                      ))}
                      {preview.hasMore ? (
                        <div className="px-3 py-2 ui-text-xs text-subtle-foreground">
                          {t("git.pushDialog.moreCommits")}
                        </div>
                      ) : null}
                    </div>
                  )}
                </section>

                <section className="flex min-h-0 flex-col">
                  <div className="flex h-8 shrink-0 items-center border-border/70 border-b px-3 font-medium ui-text-sm">
                    {t("git.pushDialog.changedFiles")}
                    {selectedCommit ? (
                      <span className="ml-auto min-w-0 truncate font-mono ui-text-xs text-subtle-foreground">
                        {selectedCommit.shortHash}
                      </span>
                    ) : null}
                  </div>
                  {!selectedCommit ? (
                    <StateMessage>{t("git.pushDialog.noCommitSelected")}</StateMessage>
                  ) : filesLoading ? (
                    <StateMessage>{t("git.pushDialog.loadingFiles")}</StateMessage>
                  ) : filesFailed ? (
                    <StateMessage danger>{t("git.pushDialog.filesFailed")}</StateMessage>
                  ) : files.length === 0 ? (
                    <StateMessage>{t("git.pushDialog.noChangedFiles")}</StateMessage>
                  ) : (
                    <GitCommitFileTree
                      files={files}
                      selectedPath={selectedPath}
                      onSelect={setSelectedPath}
                      onOpen={setSelectedPath}
                    />
                  )}
                </section>
              </div>
            </>
          ) : null}
        </div>

        {pushError ? (
          <div className="shrink-0 border-destructive/25 border-t bg-destructive/10 px-4 py-2 ui-text-sm text-destructive">
            {pushError}
          </div>
        ) : null}
        <DialogFooter className="min-h-14 items-center justify-between px-3 py-2 sm:flex-row">
          <div className="flex min-w-0 flex-1 items-center gap-3">
            <Button
              variant="ghost"
              size="icon-xs"
              tooltip={t("git.pushDialog.forcePushHint")}
              aria-label={t("git.pushDialog.help")}
            >
              <Question />
            </Button>
            <label className="flex cursor-pointer items-center gap-2 whitespace-nowrap ui-text-sm">
              <Checkbox
                checked={pushTags}
                disabled={isPushing || loadState !== "ready"}
                onCheckedChange={(checked) => setPushTags(checked === true)}
              />
              {t("git.pushDialog.pushTags")}
            </label>
            <Select
              value={tagScope}
              options={tagOptions}
              onChange={(value) => setTagScope(value as Exclude<GitPushTagScope, "none">)}
              disabled={!pushTags || isPushing}
              size="xs"
              variant="default"
              className="w-32"
              openDirection="up"
              aria-label={t("git.pushDialog.tagScope")}
            />
          </div>

          <div className="flex shrink-0 items-center gap-3">
            <Button variant="default" disabled={isPushing} onClick={() => onComplete(false)}>
              {t("ui.cancel")}
            </Button>
            <ButtonGroup variant="accent">
              <Button
                variant="accent"
                disabled={!canPush || isPushing}
                onClick={() => void performPush(false)}
              >
                {isPushing ? t("git.pushing") : t("git.push")}
              </Button>
              <ButtonGroupSeparator />
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      variant="accent"
                      size="icon"
                      disabled={!canPush || isPushing}
                      tooltip={t("git.pushDialog.moreActions")}
                      aria-label={t("git.pushDialog.moreActions")}
                    />
                  }
                >
                  <CaretDown />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" side="top">
                  <DropdownMenuItem closeOnClick onClick={() => void performPush(true)}>
                    {t("git.pushDialog.forcePush")}
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </ButtonGroup>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function GitPushDialogHost() {
  const [queue, setQueue] = useState<GitPushDialogRequest[]>([]);

  useEffect(
    () => attachGitPushDialogHost((request) => setQueue((current) => [...current, request])),
    [],
  );

  const activeRequest = queue[0] ?? null;
  if (!activeRequest) return null;

  return (
    <GitPushDialog
      key={activeRequest.id}
      request={activeRequest}
      onComplete={(pushed) => {
        activeRequest.resolve(pushed);
        setQueue((current) => current.slice(1));
      }}
    />
  );
}
