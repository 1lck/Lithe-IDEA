import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import {
  cancelWorkspaceCommit,
  prepareWorkspaceCommit,
  stepWorkspaceCommit,
} from "../api/git-workspace-commit-api";
import { createWorkspaceCommitWorkflow } from "../services/git-workspace-commit-workflow";

export const useWorkspaceCommitStore = createWorkspaceScopedStore("git-workspace-commit", () =>
  createStore(() => ({
    workflow: createWorkspaceCommitWorkflow({
      prepare: prepareWorkspaceCommit,
      step: stepWorkspaceCommit,
      cancel: cancelWorkspaceCommit,
    }),
  })),
);
