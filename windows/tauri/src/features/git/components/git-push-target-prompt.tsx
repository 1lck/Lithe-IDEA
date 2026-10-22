import { useState } from "react";
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
import { confirmPushTarget } from "../services/git-push-target";
import type { GitPushTargetChoice } from "../types/git.types";
import type {
  WorkspaceCommitPushTarget,
  WorkspaceCommitPushTargetQuestion,
} from "../types/git-workspace-commit.types";

/**
 * Asks where a commit-and-push should go for every repository whose branch tracks a
 * differently named remote branch. Core raises these questions before it writes any
 * commit, so cancelling leaves the repositories untouched. The answer names the exact
 * remote branch shown, which Core re-checks against the live tracking configuration.
 */
export function GitPushTargetPrompt({
  questions,
  onConfirm,
  onCancel,
}: {
  questions: WorkspaceCommitPushTargetQuestion[];
  onConfirm: (answers: Record<string, WorkspaceCommitPushTarget>) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const [choices, setChoices] = useState<Record<string, GitPushTargetChoice>>({});
  const answered = questions.every((question) => choices[question.repositoryId]);
  const confirm = () => {
    if (!answered) return;
    onConfirm(
      Object.fromEntries(
        questions.map((question) => [
          question.repositoryId,
          confirmPushTarget(question, choices[question.repositoryId]!),
        ]),
      ),
    );
  };
  return (
    <Dialog open onOpenChange={(open) => (!open ? onCancel() : undefined)}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>{t("git.pushDialog.chooseTargetTitle")}</DialogTitle>
          <DialogDescription>{t("git.pushDialog.chooseTargetDescription")}</DialogDescription>
        </DialogHeader>
        <div className="max-h-80 space-y-3 overflow-auto">
          {questions.map((question) => {
            const choice = choices[question.repositoryId];
            const select = (next: GitPushTargetChoice) =>
              setChoices((current) => ({ ...current, [question.repositoryId]: next }));
            return (
              <div
                key={question.repositoryId}
                data-testid={`git-push-target-question-${question.repositoryId}`}
                className="space-y-2 rounded border border-border p-2 ui-text-sm"
              >
                {questions.length > 1 && (
                  <div className="break-all font-medium">{question.repositoryId}</div>
                )}
                <p>
                  {t("git.pushDialog.divergentWarning", {
                    branch: question.localBranch,
                    upstream: question.upstream,
                  })}
                </p>
                <div className="flex flex-col gap-2">
                  <Button
                    variant={choice === "publish" ? "accent" : "default"}
                    aria-pressed={choice === "publish"}
                    data-testid={`git-push-target-publish-${question.repositoryId}`}
                    onClick={() => select("publish")}
                  >
                    {t("git.pushDialog.publishSameName", {
                      remote: question.remote,
                      branch: question.localBranch,
                    })}
                  </Button>
                  <Button
                    variant={choice === "upstream" ? "accent" : "default"}
                    aria-pressed={choice === "upstream"}
                    data-testid={`git-push-target-upstream-${question.repositoryId}`}
                    onClick={() => select("upstream")}
                  >
                    {t("git.pushDialog.pushToUpstream", { branch: question.upstream })}
                  </Button>
                </div>
              </div>
            );
          })}
        </div>
        <DialogFooter>
          <Button variant="default" onClick={onCancel}>
            {t("ui.cancel")}
          </Button>
          <Button
            variant="accent"
            disabled={!answered}
            data-testid="git-push-target-confirm"
            onClick={confirm}
          >
            {t("ui.confirm")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
