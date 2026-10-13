import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as api from "../api/git-commits-api";
import type { GitHistorySnapshot } from "../types/git.types";
import { useGitCommitPicker } from "./use-git-commit-picker";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
let query: ReturnType<typeof spyOn<typeof api, "getGitHistory">>;
let picker: ReturnType<typeof useGitCommitPicker>;
let previousAct: boolean | undefined;
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const pending: Array<() => void> = [];
const empty: GitHistorySnapshot = {
  commits: [],
  hasMore: false,
  references: [],
  recentReferences: [],
};
function Probe({ repo, open = true }: { repo: string; open?: boolean }) {
  picker = useGitCommitPicker(repo, "test-workspace", open);
  return null;
}
const render = async (repo = "C:/workspace/A", open = true) => {
  await act(async () => root.render(<Probe repo={repo} open={open} />));
};
beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  query = spyOn(api, "getGitHistory").mockResolvedValue(empty);
});
afterEach(async () => {
  await act(async () => {
    root.unmount();
    pending.splice(0).forEach((release) => release());
  });
  query.mockRestore();
  container.remove();
  restoreDom();
  if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
  else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
});
test("failed history is distinct from an empty repository and can be retried", async () => {
  query.mockResolvedValueOnce(null);
  await render();
  expect(picker.status).toBe("failed");
  await act(async () => picker.retry());
  expect(picker.status).toBe("ready");
  expect(picker.commits).toEqual([]);
  expect(query).toHaveBeenCalledTimes(2);
});
test("unexpected history rejection also produces a recoverable failure", async () => {
  query.mockRejectedValueOnce(new Error("unavailable"));
  await render();
  expect(picker.status).toBe("failed");
});
test("late failures cannot replace a new repository snapshot", async () => {
  let release!: (value: GitHistorySnapshot | null) => void;
  query.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        release = resolve;
      }),
  );
  await render();
  pending.push(() => release(null));
  expect(picker.status).toBe("loading");
  await render("C:/workspace/B");
  expect(picker.status).toBe("ready");
  await act(async () => release(null));
  expect(picker.status).toBe("ready");
});
test("closing and reopening invalidates the previous request", async () => {
  let release!: (value: GitHistorySnapshot | null) => void;
  query.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        release = resolve;
      }),
  );
  await render();
  pending.push(() => release(null));
  await render("C:/workspace/A", false);
  expect(picker.status).toBe("idle");
  await render();
  await act(async () => release(null));
  expect(picker.status).toBe("ready");
});
