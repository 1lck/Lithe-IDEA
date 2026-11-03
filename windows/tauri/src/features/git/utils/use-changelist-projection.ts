import { useEffect, useMemo, useState } from "react";
import { frontendTrace } from "@/utils/frontend-trace";
import { projectChangelists, type ChangelistProjection } from "../api/git-changelist-core";
import type { GitFile } from "../types/git.types";
import type { WorkspaceRepositoryBinding } from "../types/git-workspace-commit.types";
import { changelistFileKey, type LocalChangelists } from "./git-changelists";

/** A projection is usable only for the exact state, status and bindings that produced it. */
export function useChangelistProjection(
  state: LocalChangelists,
  files: readonly GitFile[],
  repositories: WorkspaceRepositoryBinding[],
  fallback: string | undefined,
  enabled: boolean,
) {
  const [result, setResult] = useState<{
    state: LocalChangelists;
    files: readonly GitFile[];
    repositories: WorkspaceRepositoryBinding[];
    fallback: string | undefined;
    projection?: ChangelistProjection;
    failed?: boolean;
  }>();
  useEffect(() => {
    if (!enabled) return;
    let current = true;
    void projectChangelists(state, files, repositories, fallback).then(
      (projection) => {
        if (current) setResult({ state, files, repositories, fallback, projection });
      },
      () => {
        if (current) {
          frontendTrace("warn", "git.changelists", "ChangeList projection failed");
          setResult({ state, files, repositories, fallback, failed: true });
        }
      },
    );
    return () => {
      current = false;
    };
  }, [state, files, repositories, fallback, enabled]);
  const matches =
    enabled &&
    result?.state === state &&
    result.files === files &&
    result.repositories === repositories &&
    result.fallback === fallback;
  const projected = useMemo(() => {
    if (!matches || !result?.projection) return undefined;
    const members = new Map<string, string>();
    for (let i = 0; i < files.length; i++) {
      const key = changelistFileKey(files[i]!, fallback);
      if (!key) return undefined;
      const member = result.projection.members[i]!;
      if (members.has(key) && members.get(key) !== member) return undefined;
      members.set(key, member);
    }
    return { ...state, projection: { members, scope: result.projection.scope } };
  }, [matches, result, state, files, fallback]);
  return {
    state: projected,
    failed: Boolean(matches && (result?.failed || (result?.projection && !projected))),
  };
}
