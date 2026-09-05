import { Button } from "@/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/ui/dialog";
import { useTranslation } from "@/i18n/locale-provider";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useEffect, useMemo, useSyncExternalStore } from "react";
import { getGitPullWorkflow } from "../api/git-remotes-api";
import { useRepositoryStore } from "../stores/git-repository.store";
import type { GitPullPreflight, PullStrategy } from "../types/git.types";

interface GitPullStrategyDialogProps {
  preflight: GitPullPreflight | null;
  onSelect: (strategy: Exclude<PullStrategy, "ffOnly"> | null) => void;
}

const GitPullStrategyDialog = ({ preflight, onSelect }: GitPullStrategyDialogProps) => {
  const { t } = useTranslation();

  if (!preflight) return null;

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onSelect(null);
      }}
    >
      <DialogContent
        aria-describedby="git-pull-strategy-description"
        size="sm"
        showCloseButton={false}
        className="max-w-96 p-0"
        data-testid="git-pull-strategy-dialog"
      >
        <DialogHeader className="px-4 pt-4">
          <DialogTitle>{t("git.choosePullStrategy")}</DialogTitle>
        </DialogHeader>
        <div className="space-y-3 px-4 py-3 ui-text-sm">
          <p id="git-pull-strategy-description" className="text-subtle-foreground">
            {t("git.pullDivergedMessage", { upstream: preflight.upstream ?? "" })}
          </p>
          <div className="grid grid-cols-2 gap-2">
            <div className="rounded-md border border-border bg-raised px-3 py-2">
              <div className="text-xs text-subtle-foreground">{t("git.localAhead")}</div>
              <div className="text-base font-semibold">{preflight.ahead}</div>
            </div>
            <div className="rounded-md border border-border bg-raised px-3 py-2">
              <div className="text-xs text-subtle-foreground">{t("git.remoteAhead")}</div>
              <div className="text-base font-semibold">{preflight.behind}</div>
            </div>
          </div>
          <p className="text-xs text-subtle-foreground">{t("git.pullStrategyHint")}</p>
        </div>
        <DialogFooter>
          <Button autoFocus variant="ghost" size="xs" onClick={() => onSelect(null)}>
            {t("files.cancel")}
          </Button>
          <Button variant="default" size="xs" onClick={() => onSelect("rebase")}>
            {t("git.rebase")}
          </Button>
          <Button variant="accent" size="xs" onClick={() => onSelect("merge")}>
            {t("git.merge")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

/** Owns the single strategy prompt for Pull requests started from any Git surface. */
export function GitPullStrategyDialogHost() {
  const activeRepoPath = useRepositoryStore.use.activeRepoPath();
  const rootFolderPath = useProjectStore((state) => state.rootFolderPath);
  const repoPath = activeRepoPath ?? rootFolderPath ?? "";
  const workflow = useMemo(() => getGitPullWorkflow(repoPath), [repoPath]);
  const snapshot = useSyncExternalStore(
    workflow.subscribe,
    workflow.getSnapshot,
    workflow.getSnapshot,
  );

  useEffect(
    () => () => {
      workflow.chooseStrategy(null);
    },
    [workflow],
  );

  return (
    <GitPullStrategyDialog
      preflight={snapshot.pendingPreflight}
      onSelect={(strategy) => workflow.chooseStrategy(strategy)}
    />
  );
}
