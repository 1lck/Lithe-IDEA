import { LockIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type { DiffRevisionPair } from "../../types/git-diff.types";
import type { GitDiff } from "../../types/git.types";

export function CommitFileDiffVersionHeader({ diff, revisions, label, viewMode }: {
  diff: GitDiff;
  revisions?: DiffRevisionPair;
  label: string;
  viewMode: "split" | "unified";
}) {
  const { t } = useTranslation();
  const before = revisions
    ? revisions.before === null ? t("git.diff.emptyRevision") : revisions.before.slice(0, 8)
    : t("git.diff.previousRevision");
  const after = revisions?.after.slice(0, 8) ?? label;
  const oldPath = diff.old_path || diff.file_path || diff.new_path || "";
  const newPath = diff.new_path || diff.file_path || diff.old_path || "";
  return (
    <div className="commit-diff-version-header" data-view-mode={viewMode}>
      {[{ side: "before", revision: before, path: oldPath }, { side: "after", revision: after, path: newPath }].map(({ side, revision, path }) => (
        <div key={side} className="commit-diff-version" data-revision-side={side}
          aria-label={t(side === "before" ? "git.diff.beforeVersion" : "git.diff.afterVersion")}>
          <LockIcon className="size-4 shrink-0" aria-hidden="true" />
          <span className="shrink-0" title={side === "before" ? revisions?.before ?? before : revisions?.after ?? after}>{revision}</span>
          <span className="commit-diff-version-path" title={path}>{path}</span>
        </div>
      ))}
    </div>
  );
}
