import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { deleteTag } from "../api/git-tags-api";
import { normalizeRepositoryPath } from "../api/git-repo-api";
import type { GitReference } from "../types/git.types";

export function useGitLogTagDeletion({
  repoPath,
  scope,
  isBlocked,
  onDeleted,
}: {
  repoPath: string | null;
  scope: string;
  isBlocked: boolean;
  onDeleted: (reference: GitReference) => void | Promise<void>;
}) {
  const { t } = useTranslation();
  const latestRef = useRef({ scope, isBlocked });
  latestRef.current = { scope, isBlocked };
  const activeRef = useRef(true);
  const requestRef = useRef<symbol | null>(null);
  const [pendingScope, setPendingScope] = useState<string | null>(null);

  useEffect(() => {
    activeRef.current = true;
    return () => {
      activeRef.current = false;
      requestRef.current = null;
    };
  }, []);
  useEffect(() => {
    requestRef.current = null;
    setPendingScope(null);
  }, [scope]);

  const deleteTagReference = async (reference: GitReference) => {
    if (
      !repoPath ||
      reference.kind !== "tag" ||
      !activeRef.current ||
      latestRef.current.scope !== scope ||
      latestRef.current.isBlocked ||
      requestRef.current
    )
      return;
    if (
      reference.repositoryPath &&
      normalizeRepositoryPath(reference.repositoryPath) !== normalizeRepositoryPath(repoPath)
    )
      return;
    const request = Symbol("delete-tag");
    requestRef.current = request;
    setPendingScope(scope);
    const isCurrent = () =>
      activeRef.current && requestRef.current === request && latestRef.current.scope === scope;
    try {
      const deleted = await deleteTag(repoPath, reference.shortName);
      if (!isCurrent()) return;
      if (!deleted) throw new Error(t("git.actionFailed", { action: t("git.deleteTag") }));
      await onDeleted(reference);
      if (isCurrent()) toast.success(t("git.actionCompleted", { action: t("git.deleteTag") }));
    } catch (error) {
      if (isCurrent()) toast.error(error instanceof Error ? error.message : String(error));
    } finally {
      if (isCurrent()) {
        requestRef.current = null;
        setPendingScope(null);
      }
    }
  };

  return { deleteTagReference, isDeletingTag: pendingScope === scope };
}
