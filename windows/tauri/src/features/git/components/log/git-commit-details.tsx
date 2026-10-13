import { useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { getCommitDescription } from "../../api/git-commits-api";
import type { GitCommit } from "../../types/git.types";

/**
 * History rows carry only the subject. Reads the rest of the message for the
 * inspected commit and ignores answers for a commit that is no longer shown.
 */
function useCommitDescription(repoPath: string | null, commit: GitCommit | null): string {
  const hash = commit?.hash ?? null;
  const knownDescription = commit?.description;
  const [loaded, setLoaded] = useState<{ key: string; description: string } | null>(null);
  const key = repoPath && hash ? JSON.stringify([repoPath, hash]) : null;

  useEffect(() => {
    if (!repoPath || !hash || knownDescription !== undefined) return;
    let current = true;
    void getCommitDescription(repoPath, hash).then((description) => {
      if (current && description !== null) {
        setLoaded({ key: JSON.stringify([repoPath, hash]), description });
      }
    });
    return () => {
      current = false;
    };
  }, [repoPath, hash, knownDescription]);

  if (knownDescription !== undefined) return knownDescription;
  return loaded && loaded.key === key ? loaded.description : "";
}

/** Full message and metadata of the commit shown in the Git Log inspector. */
export function GitCommitDetails({
  repoPath,
  commit,
}: {
  repoPath: string | null;
  commit: GitCommit | null;
}) {
  const { t } = useTranslation();
  const description = useCommitDescription(repoPath, commit);

  if (!commit) {
    return (
      <div className="flex h-full items-center justify-center text-subtle-foreground">
        {t("git.log.commitDetails")}
      </div>
    );
  }

  return (
    <div className="space-y-2 select-text">
      <div className="font-medium text-foreground">{commit.message}</div>
      {description ? (
        <div className="whitespace-pre-wrap break-words text-subtle-foreground">{description}</div>
      ) : null}
      <div className="font-mono text-[11px] text-subtle-foreground">
        {commit.shortHash} · {commit.author}
        {commit.email ? ` <${commit.email}>` : ""}
      </div>
      <div className="font-mono text-[11px] text-subtle-foreground">{commit.date}</div>
      {commit.decorations ? <div className="text-primary">{commit.decorations}</div> : null}
      <div className="break-all font-mono text-[10px] text-subtle-foreground">{commit.hash}</div>
    </div>
  );
}
