import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/dialog";
import type { GitPushPreview, GitPushTargetChoice } from "../types/git.types";

/**
 * Asks where a commit-and-push should go when the branch tracks a differently
 * named remote branch. The choice has to happen before the commit is written,
 * because the push step cannot revisit it afterwards.
 */
export function GitPushTargetPrompt({
  preview,
  onChoose,
  onCancel,
}: {
  preview: GitPushPreview;
  onChoose: (choice: GitPushTargetChoice) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const remote = preview.remote;
  const upstream = preview.upstream ?? preview.remoteBranch;
  return (
    <Dialog open onOpenChange={(open) => (!open ? onCancel() : undefined)}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{t("git.pushDialog.chooseTargetTitle")}</DialogTitle>
          <DialogDescription>
            {t("git.pushDialog.divergentWarning", {
              branch: preview.localBranch,
              upstream,
            })}
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-2 py-2">
          <Button
            variant="accent"
            data-testid="git-push-target-prompt-publish"
            onClick={() => onChoose("publish")}
          >
            {t("git.pushDialog.publishSameName", {
              remote,
              branch: preview.localBranch,
            })}
          </Button>
          <Button
            variant="default"
            data-testid="git-push-target-prompt-upstream"
            onClick={() => onChoose("upstream")}
          >
            {t("git.pushDialog.pushToUpstream", { branch: upstream })}
          </Button>
        </div>
        <DialogFooter>
          <Button variant="default" onClick={onCancel}>
            {t("ui.cancel")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
