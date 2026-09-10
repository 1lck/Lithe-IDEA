import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  showPromptDialog,
} from "@/ui/dialog";
import Input from "@/ui/input";
import Textarea from "@/ui/textarea";
import { Spinner } from "@/ui/spinner";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { cancelGitHistoryOperation } from "../api/git-commits-api";
import { createBranch } from "../api/git-branches-api";
import {
  executeGitHistoryRewrite,
  getGitHistoryRewritePreview,
} from "../api/git-history-rewrite-api";
import type {
  GitHistoryRewriteOperation,
  GitHistoryRewritePreview,
  GitHistoryRewriteResult,
} from "../types/git-history-rewrite.types";
import { joinGitCommitMessage, splitGitCommitMessage } from "../utils/git-history-message";

export interface GitHistoryRewriteDialogRequest {
  id: string;
  repoPath: string;
  operation: GitHistoryRewriteOperation;
  revisions: string[];
}

type ReviewState =
  | { status: "loading" }
  | { status: "ready"; preview: GitHistoryRewritePreview }
  | { status: "failed"; message: string }
  | { status: "running"; preview: GitHistoryRewritePreview }
  | { status: "finished"; result: GitHistoryRewriteResult; preview: GitHistoryRewritePreview };

const actionLabels: Record<GitHistoryRewriteOperation, string> = {
  undoCommit: "git.undoCommit",
  editCommitMessage: "git.editCommitMessage",
  squashCommits: "git.squashCommits",
  deleteCommit: "git.deleteCommit",
};

export function GitHistoryRewriteDialog({
  request,
  onClose,
}: {
  request: GitHistoryRewriteDialogRequest;
  onClose: (result?: GitHistoryRewriteResult, originalMessage?: string) => void;
}) {
  const { t } = useTranslation();
  const [state, setState] = useState<ReviewState>({ status: "loading" });
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [attempt, setAttempt] = useState(0);
  const [copied, setCopied] = useState(false);
  const [copyFailed, setCopyFailed] = useState(false);
  const [recoveryBranch, setRecoveryBranch] = useState("");
  const [recoveryError, setRecoveryError] = useState("");
  const [creatingRecovery, setCreatingRecovery] = useState(false);
  const alive = useRef(true);
  const executing = useRef(false);
  const messageInitialized = useRef(false);
  const editsMessage =
    request.operation === "editCommitMessage" || request.operation === "squashCommits";

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  useEffect(() => {
    let current = true;
    const operationId = crypto.randomUUID();
    setState({ status: "loading" });
    void getGitHistoryRewritePreview(
      request.repoPath,
      request.operation,
      request.revisions,
      operationId,
    )
      .then((preview) => {
        if (!current) return;
        if (!messageInitialized.current) {
          const message = splitGitCommitMessage(preview.suggestedMessage);
          setTitle(message.title);
          setBody(message.body);
          messageInitialized.current = true;
        }
        setState({ status: "ready", preview });
      })
      .catch((error: unknown) => {
        if (current)
          setState({
            status: "failed",
            message: error instanceof Error ? error.message : String(error),
          });
      });
    return () => {
      current = false;
      void cancelGitHistoryOperation(operationId);
    };
  }, [attempt, request]);

  const execute = async () => {
    if (
      executing.current ||
      state.status !== "ready" ||
      !state.preview.allowed ||
      !state.preview.expectedState
    )
      return;
    if (editsMessage && !title.trim()) return;
    executing.current = true;
    setState({ status: "running", preview: state.preview });
    try {
      const result = await executeGitHistoryRewrite(
        request.repoPath,
        state.preview,
        editsMessage ? joinGitCommitMessage(title, body) : undefined,
      );
      if (alive.current) setState({ status: "finished", result, preview: state.preview });
    } catch (error) {
      // A retry always reloads Core's preview; an expected snapshot is never
      // silently replaced while executing a previously approved review.
      if (alive.current)
        setState({
          status: "failed",
          message: error instanceof Error ? error.message : String(error),
        });
    } finally {
      executing.current = false;
    }
  };

  const preview = state.status === "ready" || state.status === "running" ? state.preview : null;
  const result = state.status === "finished" ? state.result : undefined;
  const applied = result?.historyRewrite?.mutationApplied === true;
  const outcomeUnknown = result?.historyRewrite?.outcomeKnown === false;
  const failed = !!result && (!!result.operationError || (result.exitCode ?? 0) !== 0 || !applied);
  const resultMessage =
    result?.operationError?.message || result?.output || t("git.historyReview.failed");
  const close = () => {
    if (!executing.current) {
      onClose(
        result,
        state.status === "finished" ? state.preview.selectedCommits[0]?.message : undefined,
      );
    }
  };
  const createRecoveryBranch = async () => {
    const originalHead = result?.historyRewrite?.originalHead;
    if (!originalHead || creatingRecovery) return;
    const name = await showPromptDialog(t("git.historyReview.recoveryName"), {
      title: t("git.historyReview.createRecovery"),
    });
    if (!name?.trim() || !alive.current) return;
    setCreatingRecovery(true);
    setRecoveryError("");
    try {
      const created = await createBranch(request.repoPath, name.trim(), {
        fullName: originalHead,
        shortName: originalHead,
        kind: "local",
        peelsToCommit: true,
        isCurrent: false,
      });
      if (!alive.current) return;
      if (created) setRecoveryBranch(name.trim());
      else setRecoveryError(t("git.historyReview.recoveryFailed"));
    } finally {
      if (alive.current) setCreatingRecovery(false);
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) close();
      }}
    >
      <DialogContent size="lg" showCloseButton={state.status !== "running"} className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{t(actionLabels[request.operation])}</DialogTitle>
          <DialogDescription>{t("git.historyReview.description")}</DialogDescription>
        </DialogHeader>
        <div className="min-h-0 space-y-4 overflow-auto px-5 py-4 ui-text-sm">
          {state.status === "loading" ? (
            <Spinner label={t("git.historyReview.loading")} showLabel />
          ) : null}
          {state.status === "failed" ? (
            <p role="alert" className="whitespace-pre-wrap text-destructive">
              {state.message}
            </p>
          ) : null}
          {preview ? (
            <>
              <p className="break-all text-subtle-foreground">
                {preview.branch ?? t("git.detachedHead")}
              </p>
              <p>
                {t(`git.historyReview.${request.operation}`, {
                  count: preview.selectedCommits.length,
                })}
              </p>
              <div>
                <p className="mb-2 font-medium">
                  {t("git.historyReview.affected", { count: preview.affectedCommits.length })}
                </p>
                <ol className="max-h-40 overflow-auto rounded-md border border-border px-3 py-2">
                  {preview.affectedCommits.map((commit) => (
                    <li key={commit.hash} className="flex gap-2 py-1">
                      <span className="shrink-0 font-mono text-subtle-foreground">
                        {commit.hash.slice(0, 7)}
                      </span>
                      <span className="min-w-0 break-words">
                        {splitGitCommitMessage(commit.message).title}
                      </span>
                    </li>
                  ))}
                </ol>
              </div>
              {preview.blockers.length > 0 ? (
                <ul
                  role="alert"
                  className="space-y-1 rounded-md border border-destructive/30 bg-destructive/5 p-3 text-destructive"
                >
                  {preview.blockers.map((blocker, index) => (
                    <li key={`${blocker.code}:${index}`}>{blocker.message}</li>
                  ))}
                </ul>
              ) : null}
              {editsMessage ? (
                <div className="space-y-3">
                  <label className="block space-y-1">
                    <span>{t("git.historyReview.title")}</span>
                    <Input
                      value={title}
                      onChange={(event) => setTitle(event.target.value)}
                      disabled={state.status === "running"}
                      autoFocus
                    />
                  </label>
                  <p className="text-right text-subtle-foreground">
                    {t("git.historyReview.titleCharacters", { count: [...title].length })}
                  </p>
                  <label className="block space-y-1">
                    <span>{t("git.historyReview.body")}</span>
                    <Textarea
                      value={body}
                      onChange={(event) => setBody(event.target.value)}
                      disabled={state.status === "running"}
                      rows={6}
                      className="max-h-64 min-h-24"
                    />
                  </label>
                  <p className="text-right text-subtle-foreground">
                    {t("git.historyReview.totalCharacters", {
                      count: [...joinGitCommitMessage(title, body)].length,
                    })}
                  </p>
                </div>
              ) : null}
            </>
          ) : null}
          {result ? (
            <div className="space-y-3" role="status">
              <p className={failed ? "whitespace-pre-wrap text-destructive" : "font-medium"}>
                {failed ? resultMessage : t("git.historyReview.completed")}
              </p>
              {result.operationError?.details ? (
                <p className="whitespace-pre-wrap text-subtle-foreground">
                  {result.operationError.details}
                </p>
              ) : null}
              {result.warnings?.map((warning, index) => (
                <p
                  key={`${warning.code}:${index}`}
                  className="whitespace-pre-wrap text-git-modified"
                >
                  {warning.message}
                  {warning.details ? `\n${warning.details}` : ""}
                </p>
              ))}
              {result.historyRewrite?.worktreeRefresh === "failed" ? (
                <p>{t("git.historyReview.refreshFailed")}</p>
              ) : null}
              {outcomeUnknown ? <p>{t("git.historyReview.outcomeUnknown")}</p> : null}
              {result.historyRewrite?.recoveryReference ? (
                <div className="space-y-2 rounded-md border border-border p-3">
                  <p>{t("git.historyReview.recovery")}</p>
                  <code className="block break-all select-text">
                    {result.historyRewrite.recoveryReference}
                  </code>
                  <Button
                    size="sm"
                    onClick={() => {
                      void tryWriteClipboardText(result.historyRewrite!.recoveryReference).then(
                        (success) => {
                          if (!alive.current) return;
                          setCopied(success);
                          setCopyFailed(!success);
                        },
                      );
                    }}
                  >
                    {t(copied ? "git.historyReview.copied" : "git.historyReview.copyRecovery")}
                  </Button>
                  {copyFailed ? (
                    <p role="alert" className="text-destructive">
                      {t("git.historyReview.copyFailed")}
                    </p>
                  ) : null}
                  <Button
                    size="sm"
                    disabled={creatingRecovery || !!recoveryBranch}
                    onClick={() => void createRecoveryBranch()}
                  >
                    {t("git.historyReview.createRecovery")}
                  </Button>
                  {recoveryBranch ? (
                    <p>{t("git.historyReview.recoveryCreated", { name: recoveryBranch })}</p>
                  ) : null}
                  {recoveryError ? (
                    <p role="alert" className="text-destructive">
                      {recoveryError}
                    </p>
                  ) : null}
                </div>
              ) : null}
              {failed && !applied && !outcomeUnknown ? (
                <p>{t("git.historyReview.reviewAgain")}</p>
              ) : null}
            </div>
          ) : null}
        </div>
        <DialogFooter>
          <Button onClick={close} disabled={state.status === "running"}>
            {t(result ? "ui.done" : "ui.cancel")}
          </Button>
          {state.status === "failed" ||
          (state.status === "ready" && !state.preview.allowed) ||
          (failed && !applied && !outcomeUnknown) ? (
            <Button onClick={() => setAttempt((value) => value + 1)}>
              {t("git.historyReview.reload")}
            </Button>
          ) : null}
          {preview ? (
            <Button
              variant={request.operation === "deleteCommit" ? "danger" : "accent"}
              disabled={
                state.status !== "ready" ||
                !preview.allowed ||
                !preview.expectedState ||
                (editsMessage && !title.trim())
              }
              onClick={() => void execute()}
            >
              {state.status === "running"
                ? t("git.historyReview.running")
                : t(actionLabels[request.operation])}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
