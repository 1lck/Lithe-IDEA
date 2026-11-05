import { expect, mock, spyOn, test } from "bun:test";
import * as tauriCore from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/git/changelists-reducer-v1.json";
import { projectChangelists } from "./git-changelist-core";
import { changelistPathKey, type LocalChangelists } from "../utils/git-changelists";
import type { GitFile } from "../types/git.types";

test("adapts the shared reducer fixture without changing ownership semantics", async () => {
  const state: LocalChangelists = {
    lists: fixture.request.state.lists,
    activeId: fixture.request.state.activeId,
    assignments: Object.fromEntries(
      Object.entries(fixture.request.state.assignments["/repo"]).map(([path, id]) => [
        changelistPathKey("/repo", path),
        id,
      ]),
    ),
  };
  const files: GitFile[] = fixture.request.files.map(({ root, path }) => ({
    path,
    repositoryPath: root,
    repositoryRelativePath: path,
    status: "modified",
    staged: false,
  }));
  const invoke = spyOn(tauriCore, "invoke").mockImplementation(
    mock(async () => fixture.response) as typeof tauriCore.invoke,
  );
  try {
    const result = await projectChangelists(state, files, fixture.request.repositories, undefined, {
      type: "remove",
      id: "two",
    });
    expect(invoke).toHaveBeenCalledWith("git.changelists", fixture.request);
    expect(result.members).toEqual(fixture.response.members);
    expect(result.scope).toEqual(fixture.response.scope);
    expect(result.state.assignments[changelistPathKey("/repo", "dir/a")]).toBe("default");
  } finally {
    invoke.mockRestore();
  }
});
