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

const IN_PROGRESS_TITLES: Record<GitOperationKind, string> = {
  merge: "Merge in progress",
  rebase: "Rebase in progress",
  cherryPick: "Cherry-pick in progress",
  revert: "Revert in progress",
};

const CONTINUE_TITLES: Record<GitOperationKind, string> = {
  merge: "Continue Merge",
  rebase: "Continue Rebase",
  cherryPick: "Continue Cherry-pick",
  revert: "Continue Revert",
};

interface GitOperationBannerProps {
  repoPath: string;
}

/**
 * Pins the state of an in-progress merge/rebase/cherry-pick/revert above the
 * changes list. Deliberately not a dialog: the controls must stay reachable
 * while the user edits conflicted files, mirroring the macOS sidebar banner.
 */
const GitOperationBanner = ({ repoPath }: GitOperationBannerProps) => {
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
        toast.error(error instanceof Error ? error.message : "Git operation failed");
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

  return (
    <div
      className="flex flex-col gap-2 border-b border-border bg-raised px-3 py-2.5"
      role="status"
      data-testid="git-operation-banner"
    >
      <div className="flex items-center gap-2">
        <WarningIcon className="size-3.5 shrink-0 text-git-modified" />
        <span className="text-xs font-semibold">{IN_PROGRESS_TITLES[operation.kind]}</span>
        {operation.reference ? (
          <span className="truncate text-xs text-subtle-foreground">
            — {operation.reference.slice(0, 7)}
          </span>
        ) : null}
      </div>

      <div className="text-xs leading-relaxed text-subtle-foreground">
        {hasProgress ? <span>Step {operation.step} of {operation.total}. </span> : null}
        {hasConflicts ? (
          <span>
            Resolve {operation.conflictedPaths.length} conflicted file
            {operation.conflictedPaths.length === 1 ? "" : "s"}, stage them, then continue.
          </span>
        ) : (
          <span>All conflicts resolved. Continue to finish, or abort to undo.</span>
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
          {CONTINUE_TITLES[operation.kind]}
        </Button>
        {operation.kind === "rebase" ? (
          <Button
            variant="ghost"
            size="xs"
            disabled={isResolving}
            onClick={() => void resolve(skipOperationStep)}
            className="h-6 px-2 text-xs"
          >
            Skip Commit
          </Button>
        ) : null}
        <Button
          variant="ghost"
          size="xs"
          disabled={isResolving}
          onClick={() => void resolve(abortOperation)}
          className={cn("h-6 px-2 text-xs text-git-deleted hover:text-git-deleted")}
        >
          Abort
        </Button>
      </div>
    </div>
  );
};

export default GitOperationBanner;
