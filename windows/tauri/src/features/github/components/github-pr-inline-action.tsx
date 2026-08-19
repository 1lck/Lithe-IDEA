import { useEffect, useMemo, useState } from "react";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import { Spinner } from "@/ui/spinner";
import { GitHubMarkdownEditor } from "./github-markdown-editor";

export type GitHubPRInlineActionKind = "comment" | "approve" | "request-changes" | "merge";
export type GitHubPRMergeMethod = "merge" | "squash" | "rebase";

const actionCopy = {
  comment: {
    titleKey: "github.addComment",
    placeholderKey: "github.writeComment",
    submitLabelKey: "github.comment",
    requiresBody: true,
  },
  approve: {
    titleKey: "github.approvePullRequest",
    placeholderKey: "github.optionalReviewNote",
    submitLabelKey: "github.approve",
    requiresBody: false,
  },
  "request-changes": {
    titleKey: "github.requestChanges",
    placeholderKey: "github.describeRequestedChanges",
    submitLabelKey: "github.requestChanges",
    requiresBody: true,
  },
  merge: {
    titleKey: "github.mergePullRequest",
    submitLabelKey: "github.merge",
    requiresBody: false,
  },
} as const;

interface GitHubPRInlineActionProps {
  kind: GitHubPRInlineActionKind;
  isSubmitting: boolean;
  onCancel: () => void;
  onSubmit: (body: string, method: GitHubPRMergeMethod) => Promise<void>;
}

export function GitHubPRInlineAction({
  kind,
  isSubmitting,
  onCancel,
  onSubmit,
}: GitHubPRInlineActionProps) {
  const { t } = useTranslation();
  const [body, setBody] = useState("");
  const [method, setMethod] = useState<GitHubPRMergeMethod>("squash");
  const copy = actionCopy[kind];
  const canSubmit = useMemo(
    () => !isSubmitting && (!copy.requiresBody || body.trim().length > 0),
    [body, copy.requiresBody, isSubmitting],
  );

  useEffect(() => {
    setBody("");
    setMethod("squash");
  }, [kind]);

  return (
    <section className="space-y-3 rounded-lg border border-border/70 bg-surface/35 p-3">
      <h2 className="font-sans ui-text-sm font-medium text-foreground">{t(copy.titleKey)}</h2>
      {kind === "merge" ? (
        <div className="flex flex-wrap items-center gap-1">
          {(["squash", "merge", "rebase"] as const).map((option) => (
            <Button
              key={option}
              type="button"
              variant="ghost"
              active={method === option}
              onClick={() => setMethod(option)}
              size="xs"
              className="capitalize"
              disabled={isSubmitting}
            >
              {option}
            </Button>
          ))}
        </div>
      ) : (
        <GitHubMarkdownEditor
          value={body}
          onChange={setBody}
          placeholder={"placeholderKey" in copy ? t(copy.placeholderKey) : t("github.writeReview")}
          autoFocus
          minHeight={160}
          disabled={isSubmitting}
        />
      )}
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" size="xs" onClick={onCancel} disabled={isSubmitting}>
          {t("github.cancel")}
        </Button>
        <Button
          type="button"
          variant="accent"
          size="xs"
          onClick={() => void onSubmit(body, method)}
          disabled={!canSubmit}
        >
          {isSubmitting ? <Spinner label={t("github.working")} compact /> : null}
          {t(copy.submitLabelKey)}
        </Button>
      </div>
    </section>
  );
}
