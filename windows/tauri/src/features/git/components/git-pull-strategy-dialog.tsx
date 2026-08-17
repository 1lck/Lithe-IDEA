import { Button } from "@/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/ui/dialog";
import type { GitPullPreflight, PullStrategy } from "../types/git.types";

interface GitPullStrategyDialogProps {
  preflight: GitPullPreflight | null;
  onSelect: (strategy: Exclude<PullStrategy, "ffOnly"> | null) => void;
}

const GitPullStrategyDialog = ({ preflight, onSelect }: GitPullStrategyDialogProps) => {
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
          <DialogTitle>Choose Pull Strategy</DialogTitle>
        </DialogHeader>
        <div className="space-y-3 px-4 py-3 ui-text-sm">
          <p id="git-pull-strategy-description" className="text-subtle-foreground">
            The current branch and{" "}
            <span className="font-medium text-foreground">{preflight.upstream}</span> have diverged.
            Choose how to reconcile them.
          </p>
          <div className="grid grid-cols-2 gap-2">
            <div className="rounded-md border border-border bg-raised px-3 py-2">
              <div className="text-xs text-subtle-foreground">Local ahead</div>
              <div className="text-base font-semibold">{preflight.ahead}</div>
            </div>
            <div className="rounded-md border border-border bg-raised px-3 py-2">
              <div className="text-xs text-subtle-foreground">Remote ahead</div>
              <div className="text-base font-semibold">{preflight.behind}</div>
            </div>
          </div>
          <p className="text-xs text-subtle-foreground">
            Merge creates a merge commit. Rebase replays local commits on the upstream branch.
          </p>
        </div>
        <DialogFooter>
          <Button autoFocus variant="ghost" size="xs" onClick={() => onSelect(null)}>
            Cancel
          </Button>
          <Button variant="default" size="xs" onClick={() => onSelect("rebase")}>
            Rebase
          </Button>
          <Button variant="accent" size="xs" onClick={() => onSelect("merge")}>
            Merge
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default GitPullStrategyDialog;
