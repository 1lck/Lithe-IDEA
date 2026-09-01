import { useState } from "react";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { showChoiceDialog, showConfirmDialog, showPromptDialog } from "@/ui/dialog";
import {
  cherryPickCommit,
  deleteCommit,
  editCommitMessage,
  resetToCommit,
  squashCommits,
  type GitResetMode,
} from "../api/git-commits-api";
import type { GitCommit } from "../types/git.types";

export function useGitHistoryMutations({
  repoPath,
  onCompleted,
}: {
  repoPath?: string | null;
  onCompleted: () => void | Promise<void>;
}) {
  const { t } = useTranslation();
  const [isMutatingHistory, setIsMutatingHistory] = useState(false);

  const runMutation = async (mutation: () => Promise<void>) => {
    setIsMutatingHistory(true);
    try {
      await mutation();
      await onCompleted();
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : typeof error === "object" && error && "message" in error
            ? String(error.message)
            : String(error);
      toast.error(message || t("git.historyMutationFailed"));
    } finally {
      setIsMutatingHistory(false);
    }
  };

  const editMessage = async (commit: GitCommit) => {
    if (!repoPath) return;
    const message = await showPromptDialog(
      t("git.editCommitMessagePrompt", { hash: commit.shortHash }),
      {
        title: t("git.editCommitMessage"),
        confirmLabel: t("git.saveCommitMessage"),
        defaultValue: commit.message,
      },
    );
    if (!message?.trim() || message.trim() === commit.message) return;
    await runMutation(() => editCommitMessage(repoPath, commit.hash, message.trim()));
  };

  const removeCommit = async (commit: GitCommit) => {
    if (
      !repoPath ||
      !(await showConfirmDialog(
        t("git.deleteCommitConfirm", { hash: commit.shortHash, message: commit.message }),
        {
          title: t("git.deleteCommit"),
          confirmLabel: t("git.deleteCommit"),
        },
      ))
    ) {
      return;
    }
    await runMutation(() => deleteCommit(repoPath, commit.hash));
  };

  const squashSelectedCommits = async (commits: GitCommit[]) => {
    if (!repoPath || commits.length < 2) return;
    const oldestCommit = commits[commits.length - 1];
    const message = await showPromptDialog(t("git.squashCommitsPrompt", { count: commits.length }), {
      title: t("git.squashCommits"),
      confirmLabel: t("git.squash"),
      defaultValue: oldestCommit.message,
    });
    if (!message?.trim()) return;
    await runMutation(() =>
      squashCommits(
        repoPath,
        commits.map((commit) => commit.hash),
        message.trim(),
      ),
    );
  };

  const resetBranchToCommit = async (commit: GitCommit) => {
    if (!repoPath) return;
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
    if (!mode) return;
    await runMutation(() => resetToCommit(repoPath, commit.hash, mode));
  };

  const cherryPickSelectedCommit = async (commit: GitCommit) => {
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
    await runMutation(() => cherryPickCommit(repoPath, commit.hash));
  };

  return {
    isMutatingHistory,
    editMessage,
    removeCommit,
    squashSelectedCommits,
    resetBranchToCommit,
    cherryPickSelectedCommit,
  };
}
