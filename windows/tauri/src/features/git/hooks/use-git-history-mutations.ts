import { createElement, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { showChoiceDialog, showConfirmDialog } from "@/ui/dialog";
import { cherryPickCommit, resetToCommit, type GitResetMode } from "../api/git-commits-api";
import type { GitCommit } from "../types/git.types";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useUIState } from "@/features/window/stores/ui-state.store";
import {
  GitHistoryRewriteDialog,
  type GitHistoryRewriteDialogRequest,
} from "../components/git-history-rewrite-dialog";
import type {
  GitHistoryRewriteOperation,
  GitHistoryRewriteResult,
} from "../types/git-history-rewrite.types";
import { useGitStore } from "../stores/git.store";

export function useGitHistoryMutations({
  repoPath,
  onCompleted,
}: {
  repoPath?: string | null;
  onCompleted: () => void | Promise<void>;
}) {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const scope = `${workspaceId}\0${repoPath ?? ""}`;
  const scopeRef = useRef(scope);
  scopeRef.current = scope;
  const epochRef = useRef(0);
  const pendingRef = useRef(false);
  const [isRunning, setIsRunning] = useState(false);
  const [review, setReview] = useState<(GitHistoryRewriteDialogRequest & { scope: string }) | null>(
    null,
  );

  useEffect(() => {
    setReview(null);
    setIsRunning(false);
    pendingRef.current = false;
    return () => {
      epochRef.current += 1;
    };
  }, [scope]);

  const runMutation = async (mutation: () => Promise<void>) => {
    if (pendingRef.current || scopeRef.current !== scope) return;
    const epoch = epochRef.current;
    const isCurrent = () => epoch === epochRef.current && scopeRef.current === scope;
    pendingRef.current = true;
    setIsRunning(true);
    try {
      await mutation();
      if (isCurrent()) await onCompleted();
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : typeof error === "object" && error && "message" in error
            ? String(error.message)
            : String(error);
      if (isCurrent()) toast.error(message || t("git.historyMutationFailed"));
    } finally {
      if (isCurrent()) {
        pendingRef.current = false;
        setIsRunning(false);
      }
    }
  };

  const openReview = (operation: GitHistoryRewriteOperation, commits: GitCommit[]) => {
    if (!repoPath || pendingRef.current || review) return;
    setReview({
      id: crypto.randomUUID(),
      repoPath,
      operation,
      revisions: commits.map((commit) => commit.hash),
      scope,
    });
  };

  const undoCommit = (commit: GitCommit) => openReview("undoCommit", [commit]);
  const editMessage = (commit: GitCommit) => openReview("editCommitMessage", [commit]);
  const removeCommit = (commit: GitCommit) => openReview("deleteCommit", [commit]);
  const squashSelectedCommits = (commits: GitCommit[]) => {
    if (commits.length >= 2) openReview("squashCommits", commits);
  };

  const closeReview = async (result?: GitHistoryRewriteResult, originalMessage?: string) => {
    const epoch = epochRef.current;
    if (scopeRef.current !== scope) return;
    setReview(null);
    if (!result) return;
    await onCompleted();
    if (epoch !== epochRef.current || scopeRef.current !== scope) return;
    if (review?.operation === "undoCommit" && result.historyRewrite?.mutationApplied) {
      const git = useGitStore.getStore(workspaceId).getState();
      if (originalMessage && !git.sourceControlSessions[review.repoPath]?.commitMessage.trim()) {
        git.actions.updateSourceControlSession(review.repoPath, { commitMessage: originalMessage });
      }
      const ui = useUIState.getStore(workspaceId).getState();
      ui.setIsSidebarVisible(true);
      ui.setActiveView("git");
      window.dispatchEvent(
        new CustomEvent("lithe:git-palette-action", {
          detail: { type: "show-tab", tab: "changes" },
        }),
      );
    }
  };

  const resetBranchToCommit = async (commit: GitCommit) => {
    if (!repoPath) return;
    const epoch = epochRef.current;
    const mode = await showChoiceDialog<GitResetMode>(
      t("git.resetToCommitPrompt", { hash: commit.shortHash }),
      {
        title: t("git.resetToCommit"),
        choices: [
          { value: "soft", label: t("git.resetSoft") },
          { value: "mixed", label: t("git.resetMixed"), variant: "accent" },
          { value: "hard", label: t("git.resetHard"), variant: "danger" },
        ],
      },
    );
    if (!mode || epoch !== epochRef.current) return;
    await runMutation(() => resetToCommit(repoPath, commit.hash, mode));
  };

  const cherryPickSelectedCommit = async (commit: GitCommit) => {
    const epoch = epochRef.current;
    if (
      !repoPath ||
      !(await showConfirmDialog(
        t("git.cherryPickCommitConfirm", { hash: commit.shortHash, message: commit.message }),
        {
          title: t("git.cherryPickCommit"),
          confirmLabel: t("git.cherryPickCommit"),
        },
      ))
    ) {
      return;
    }
    if (epoch === epochRef.current)
      await runMutation(() => cherryPickCommit(repoPath, commit.hash));
  };

  return {
    isMutatingHistory: isRunning || (review !== null && review.scope === scope),
    historyDialog:
      review?.scope === scope && workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId
        ? createElement(GitHistoryRewriteDialog, {
            key: review.id,
            request: review,
            onClose: (result, originalMessage) => {
              void closeReview(result, originalMessage).catch((error) =>
                toast.error(String(error)),
              );
            },
          })
        : null,
    undoCommit,
    editMessage,
    removeCommit,
    squashSelectedCommits,
    resetBranchToCommit,
    cherryPickSelectedCommit,
  };
}
