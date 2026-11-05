import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as core from "../api/git-changelist-core";
import type { GitFile } from "../types/git.types";
import { EMPTY_CHANGELISTS, fileChangelist } from "./git-changelists";
import { useChangelistProjection } from "./use-changelist-projection";

const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
};
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let restore = () => {};
afterEach(() => {
  restore();
});

test("an older projection cannot publish after status changes", async () => {
  restore = installHappyDom();
  const previous = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const first = deferred<core.ChangelistProjection>();
  const second = deferred<core.ChangelistProjection>();
  const project = spyOn(core, "projectChangelists")
    .mockImplementationOnce(() => first.promise)
    .mockImplementationOnce(() => second.promise);
  const repo = [{ id: "A", root: "/repo" }];
  const oldFile: GitFile = {
    path: "old",
    repositoryPath: "/repo",
    status: "modified",
    staged: false,
  };
  const newFile: GitFile = {
    path: "new",
    repositoryPath: "/repo",
    status: "modified",
    staged: false,
  };
  const oldFiles = [oldFile],
    newFiles = [newFile];
  function View({ files }: { files: GitFile[] }) {
    const projected = useChangelistProjection(EMPTY_CHANGELISTS, files, repo, undefined, true);
    return <div>{projected.state ? fileChangelist(projected.state, files[0]!) : "pending"}</div>;
  }
  try {
    await act(async () => root.render(<View files={oldFiles} />));
    await act(async () => root.render(<View files={newFiles} />));
    expect(container.textContent).toBe("pending");
    await act(async () => {
      second.resolve({
        state: EMPTY_CHANGELISTS,
        members: ["default"],
        scope: { include: false, paths: {} },
      });
      await second.promise;
    });
    expect(container.textContent).toBe("default");
    await act(async () => {
      first.resolve({
        state: EMPTY_CHANGELISTS,
        members: ["default"],
        scope: { include: true, paths: {} },
      });
      await first.promise;
    });
    expect(container.textContent).toBe("default");
    expect(project).toHaveBeenCalledTimes(2);
  } finally {
    first.resolve({
      state: EMPTY_CHANGELISTS,
      members: ["default"],
      scope: { include: false, paths: {} },
    });
    second.resolve({
      state: EMPTY_CHANGELISTS,
      members: ["default"],
      scope: { include: false, paths: {} },
    });
    await act(async () => root.unmount());
    project.mockRestore();
    container.remove();
    if (previous === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previous;
  }
}, 1000);
