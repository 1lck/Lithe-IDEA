import { LockIcon } from "@/ui/icons";
import { Checkbox } from "@/ui/checkbox";
import { useTranslation } from "@/i18n/locale-provider";
import type { DiffRevisionPair } from "../../types/git-diff.types";
import type { GitDiff } from "../../types/git.types";

export function CommitFileDiffVersionHeader({ diff, revisions, label, viewMode, workingTree }: {
  diff: GitDiff;
  revisions?: DiffRevisionPair;
  label: string;
  viewMode: "split" | "unified";
  workingTree?: { staged: boolean; included: boolean; indeterminate: boolean; disabled: boolean;
    onToggle: (included: boolean) => void };
}) {
  const { t } = useTranslation();
  const before = workingTree ? "HEAD" : revisions
    ? revisions.before === null ? t("git.diff.emptyRevision") : revisions.before.slice(0, 8)
    : t("git.diff.previousRevision");
  const after = workingTree ? t(workingTree.staged ? "git.diff.indexVersion" : "git.diff.currentVersion")
    : revisions?.after.slice(0, 8) ?? label;
  const oldPath = diff.old_path || diff.file_path || diff.new_path || "";
  const newPath = diff.new_path || diff.file_path || diff.old_path || "";
  const versions = [
    { side: "before", revision: before, path: oldPath },
    { side: "after", revision: after, path: newPath },
  ].filter(({ side }) => diff.is_new ? side === "after" : diff.is_deleted ? side === "before" : true);
  return (
    <div className="commit-diff-version-header" data-view-mode={viewMode}
      data-single-version={versions.length === 1}>
      {versions.map(({ side, revision, path }) => (
        <div key={side} className="commit-diff-version" data-revision-side={side}
          aria-label={t(side === "before" ? "git.diff.beforeVersion" : "git.diff.afterVersion")}>
          {workingTree && (side === "after" || diff.is_deleted) ? (
            <Checkbox checked={workingTree.included} indeterminate={workingTree.indeterminate}
              disabled={workingTree.disabled}
              onCheckedChange={included => workingTree.onToggle(workingTree.indeterminate ? true : included)}
              aria-label={t(workingTree.included ? "git.excludeFileFromCommit" : "git.includeFileInCommit", { name: newPath })} />
          ) : <LockIcon className="size-4 shrink-0" aria-hidden="true" />}
          <span className="shrink-0" title={side === "before" ? revisions?.before ?? before : revisions?.after ?? after}>{revision}</span>
          <span className="commit-diff-version-path" title={path}>{path}</span>
        </div>
      ))}
    </div>
  );
}
