import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/dialog";
import type { WorkspaceCommitPreparation } from "../types/git-workspace-commit.types";

export function GitWorkspaceCommitReview({
  preparation,
  busy,
  error,
  onConfirm,
  onClose,
  onIncludeParents,
}: {
  preparation: WorkspaceCommitPreparation;
  busy: boolean;
  error: string | null;
  onConfirm: () => void;
  onClose: () => void;
  onIncludeParents: (include: boolean) => void;
}) {
  const { t } = useTranslation();
  const plan = preparation.session.plan;
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) onClose();
      }}
    >
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{t("git.workspaceCommit.review")}</DialogTitle>
          <DialogDescription>{t("git.workspaceCommit.order")}</DialogDescription>
        </DialogHeader>
        {preparation.reviewChanged && <p role="alert">{t("git.workspaceCommit.changed")}</p>}
        {error && (
          <p role="alert" className="text-destructive">
            {error}
          </p>
        )}
        <p className="whitespace-pre-wrap break-words">{plan.message}</p>
        <label className="flex items-center gap-2">
          <Checkbox
            checked={plan.includeParentReferences}
            onCheckedChange={onIncludeParents}
            disabled={busy}
          />
          {t("git.workspaceCommit.parents")}
        </label>
        <ol className="max-h-80 space-y-3 overflow-auto">
          {plan.orderedIds.map((id, index) => {
            const state = plan.states[id];
            return (
              <li key={id} className="rounded border border-border p-2 ui-text-sm">
                <div>
                  {index + 1}. {id}
                </div>
                <div className="break-all text-subtle-foreground">
                  {plan.repositories.find((repo) => repo.id === id)?.root}
                </div>
                <div className="break-all">
                  {state?.branch ?? "HEAD"} · {state?.head ?? "—"}
                </div>
                {plan.committedIds.includes(id) && <div>{t("git.workspaceCommit.pushOnly")}</div>}
                <ul>
                  {state?.stagedPaths.map((path) => (
                    <li key={path} className="break-all">
                      {path}
                    </li>
                  ))}
                </ul>
                {plan.propagatedRelations
                  .filter((relation) => relation.parent === id)
                  .map((relation) => (
                    <div key={relation.path}>
                      {t("git.workspaceCommit.reference", {
                        path: relation.path,
                        child: relation.child,
                      })}
                    </div>
                  ))}
              </li>
            );
          })}
        </ol>
        <DialogFooter>
          <Button onClick={onClose} disabled={busy}>
            {t("common.cancel")}
          </Button>
          <Button onClick={onConfirm} disabled={busy}>
            {t(plan.push ? "git.commitAndPush" : "git.commit")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
