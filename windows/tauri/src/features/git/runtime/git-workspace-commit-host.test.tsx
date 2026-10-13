import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import { useGitStore } from "../stores/git.store";
import { GitWorkspaceCommitHost } from "./git-workspace-commit-host";
import fixture from "../../../../../../shared/fixtures/git/workspace-commit-workflow-v1.json";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
beforeEach(() => {
  registry.resetForTests();
  registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  restoreDom();
  registry.resetForTests();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

test("workbench host keeps a batch across panel rerenders and disposes it on workspace switch", async () => {
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  const dispose = spyOn(workflow, "dispose");
  try {
    await act(async () => root.render(<GitWorkspaceCommitHost />));
    await act(async () => root.render(<GitWorkspaceCommitHost />));
    expect(dispose).not.toHaveBeenCalled();
    await act(async () => registry.activateWorkspace({ id: "B", name: "B" }, "ready"));
    expect(dispose).toHaveBeenCalledTimes(1);
  } finally {
    dispose.mockRestore();
  }
});

test.each(["commit", "new draft"])(
  "completion clears only the unchanged originating draft (%s)",
  async (message) => {
    const owner = useWorkspaceCommitStore.getStore("A").getState();
    owner.setDraftOwner("/workspace/A");
    useGitStore
      .getStore("A")
      .getState()
      .actions.updateSourceControlSession("/workspace/A", { commitMessage: message });
    await act(async () => root.render(<GitWorkspaceCommitHost />));
    await act(async () =>
      owner.workflow.setState({
        session: { ...fixture.preparation.session, finished: true, succeeded: true },
      }),
    );
    expect(
      useGitStore.getStore("A").getState().sourceControlSessions["/workspace/A"]?.commitMessage,
    ).toBe(message === "commit" ? "" : message);
    expect(useWorkspaceCommitStore.getStore("A").getState().draftOwner).toBeNull();
  },
);
