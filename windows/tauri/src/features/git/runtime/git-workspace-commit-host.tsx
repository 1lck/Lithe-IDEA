import { useEffect, useSyncExternalStore } from "react";
import {
  useActiveWorkspaceId,
  useWorkspaceReady,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import { useGitStore } from "../stores/git.store";
import { useGitBlameStore } from "../stores/git-blame.store";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";

/** Workbench lifetime: hiding the Git sidebar must not stop a workspace batch. */
export function GitWorkspaceCommitHost() {
  const workspaceId = useActiveWorkspaceId();
  const ready = useWorkspaceReady(workspaceId);
  const workflow = useWorkspaceCommitStore((state) => state.workflow);
  const draftOwner = useWorkspaceCommitStore((state) => state.draftOwner);
  const setDraftOwner = useWorkspaceCommitStore((state) => state.setDraftOwner);
  const batch = useSyncExternalStore(workflow.subscribe, workflow.getState, workflow.getState);
  useEffect(() => {
    if (!ready || !batch.session?.succeeded || !draftOwner) return;
    const git = useGitStore.getStore(workspaceId).getState();
    // Read the live draft: typing during confirmation must never be lost.
    if (
      git.sourceControlSessions[draftOwner]?.commitMessage.trim() === batch.session.plan.message
    ) {
      git.actions.updateSourceControlSession(draftOwner, { commitMessage: "" });
    }
    useGitBlameStore.getStore(workspaceId).getState().actions.clearAllBlame();
    setDraftOwner(null);
  }, [batch.session, draftOwner, ready, setDraftOwner, workspaceId]);
  useEffect(() => {
    if (!ready) workflow.dispose();
    return () => workflow.dispose();
  }, [workflow, workspaceId, ready]);
  return null;
}
