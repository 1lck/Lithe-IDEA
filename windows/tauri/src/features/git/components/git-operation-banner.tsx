import { useCallback, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/ui/button";
import { WarningIcon } from "@/ui/icons";
import {
  abortOperation,
  continueOperation,
  skipOperationStep,
  type OperationResolution,
} from "../api/git-integration-api";
import { useGitStore } from "../stores/git.store";
import { cn } from "@/utils/cn";
import type { GitOperationKind } from "../types/git.types";
import { useTranslation } from "@/i18n/locale-provider";

interface GitOperationBannerProps {
  repoPath: string;
}

/**
 * Pins the state of an in-progress merge/rebase/cherry-pick/revert above the
 * changes list. Deliberately not a dialog: the controls must stay reachable
 * while the user edits conflicted files, mirroring the macOS sidebar banner.
 */
const GitOperationBanner = ({ repoPath }: GitOperationBannerProps) => {
  const { t } = useTranslation();
  const operation = useGitStore((state) => state.operationState);

  const [isResolving, setIsResolving] = useState(false);

  const resolve = useCallback(
    async (action: (repoPath: string) => Promise<OperationResolution>) => {
      setIsResolving(true);
      try {
        const result = await action(repoPath);
        // A rejected continue can still change state; the API already
        // requested a refresh either way, so only surface the message here.
        if (!result.ok) {
          toast.error(result.message);
        }
      } catch (error) {
        toast.error(error instanceof Error ? error.message : t("git.operationFailed"));
      } finally {
        setIsResolving(false);
      }
    },
    [repoPath, toast],
  );

  if (!operation) {
    return null;
  }

  const hasConflicts = operation.conflictedPaths.length > 0;
  const hasProgress = operation.step != null && operation.total != null;
  const inProgressTitles: Record<GitOperationKind, string> = {
    merge: t("git.mergeInProgress"),
    rebase: t("git.rebaseInProgress"),
    cherryPick: t("git.cherryPickInProgress"),
    revert: t("git.revertInProgress"),
  };
  const continueTitles: Record<GitOperationKind, string> = {
    merge: t("git.continueMerge"),
    rebase: t("git.continueRebase"),
    cherryPick: t("git.continueCherryPick"),
    revert: t("git.continueRevert"),
  };

  return (
    <div
      className="flex flex-col gap-2 border-b border-border bg-raised px-3 py-2.5"
      role="status"
      data-testid="git-operation-banner"
    >
      <div className="flex items-center gap-2">
        <WarningIcon className="size-3.5 shrink-0 text-git-modified" />
        <span className="text-xs font-semibold">{inProgressTitles[operation.kind]}</span>
        {operation.reference ? (
          <span className="truncate text-xs text-subtle-foreground">
            — {operation.reference.slice(0, 7)}
          </span>
        ) : null}
      </div>

      <div className="text-xs leading-relaxed text-subtle-foreground">
        {hasProgress ? (
          <span>
            {t("git.operationStep", {
              step: operation.step ?? 0,
              total: operation.total ?? 0,
            })}{" "}
          </span>
        ) : null}
        {hasConflicts ? (
          <span>
            {t("git.resolveConflicts", {
              count: operation.conflictedPaths.length,
              plural: operation.conflictedPaths.length === 1 ? "" : "s",
            })}
          </span>
        ) : (
          <span>{t("git.conflictsResolved")}</span>
        )}
      </div>

      <div className="flex items-center gap-2">
        <Button
          variant="default"
          size="xs"
          disabled={isResolving || hasConflicts}
          onClick={() => void resolve(continueOperation)}
          className="h-6 px-2 text-xs"
        >
          {continueTitles[operation.kind]}
        </Button>
        {operation.kind === "rebase" ? (
          <Button
            variant="ghost"
            size="xs"
            disabled={isResolving}
            onClick={() => void resolve(skipOperationStep)}
            className="h-6 px-2 text-xs"
          >
            {t("git.skipCommit")}
          </Button>
        ) : null}
        <Button
          variant="ghost"
          size="xs"
          disabled={isResolving}
          onClick={() => void resolve(abortOperation)}
          className={cn("h-6 px-2 text-xs text-git-deleted hover:text-git-deleted")}
        >
          {t("git.abort")}
        </Button>
      </div>
    </div>
  );
};

export default GitOperationBanner;
