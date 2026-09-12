import { describe, expect, test } from "bun:test";
import { useGitLogPreferencesStore } from "./git-log-preferences.store";

describe("Git Log preferences", () => {
  test("persists read-only view preferences through focused actions", () => {
    const actions = useGitLogPreferencesStore.getState().actions;
    const repoPath = "C:/work/project";

    actions.setFilterQuery("graph");
    actions.setFilterScope("author");
    actions.setShowDecorations(false);
    actions.setShowMyBranchesOnly(true);
    actions.setMainPanelLayout({ references: 20, commits: 55, inspector: 25 });
    actions.setInspectorPanelLayout({ files: 70, details: 30 });
    actions.toggleReferenceSection("remote");
    actions.toggleReferenceGroup("remote:origin");
    actions.toggleMarkedReference(repoPath, "refs/heads/main");

    expect(useGitLogPreferencesStore.getState()).toMatchObject({
      filterQuery: "graph",
      filterScope: "author",
      showDecorations: false,
      showMyBranchesOnly: true,
      mainPanelLayout: { references: 20, commits: 55, inspector: 25 },
      inspectorPanelLayout: { files: 70, details: 30 },
      collapsedReferenceSections: ["remote"],
      collapsedReferenceGroups: ["remote:origin"],
      markedReferenceFullNamesByRepository: {
        [repoPath]: ["refs/heads/main"],
      },
    });

    actions.setReferenceExpansion(["local", "remote", "tag"], ["local:feature"]);
    expect(useGitLogPreferencesStore.getState()).toMatchObject({
      collapsedReferenceSections: ["local", "remote", "tag"],
      collapsedReferenceGroups: ["local:feature"],
    });

    actions.setFilterQuery("");
    actions.setFilterScope("text");
    actions.setShowDecorations(true);
    actions.setShowMyBranchesOnly(false);
    actions.setMainPanelLayout({ references: 19, commits: 57, inspector: 24 });
    actions.setInspectorPanelLayout({ files: 62, details: 38 });
    actions.setReferenceExpansion([], []);
    actions.toggleMarkedReference(repoPath, "refs/heads/main");
  });

  test("isolates marked references by normalized repository path", () => {
    const actions = useGitLogPreferencesStore.getState().actions;

    actions.toggleMarkedReference("C:\\work\\one\\", "refs/heads/feature/demo");
    actions.toggleMarkedReference("C:/work/two", "refs/heads/feature/demo");

    expect(useGitLogPreferencesStore.getState().markedReferenceFullNamesByRepository).toEqual({
      "C:/work/one": ["refs/heads/feature/demo"],
      "C:/work/two": ["refs/heads/feature/demo"],
    });

    actions.toggleMarkedReference("C:/work/one", "refs/heads/feature/demo");
    expect(useGitLogPreferencesStore.getState().markedReferenceFullNamesByRepository).toEqual({
      "C:/work/two": ["refs/heads/feature/demo"],
    });

    actions.toggleMarkedReference("C:/work/two", "refs/heads/feature/demo");
  });

  test("migrates marked references when a branch is renamed", () => {
    const actions = useGitLogPreferencesStore.getState().actions;
    const repoPath = "C:/work/rename";
    const oldFullName = "refs/heads/feature/old-name";
    const newFullName = "refs/heads/feature/new-name";

    actions.toggleMarkedReference(repoPath, oldFullName);
    actions.renameMarkedReference(repoPath, oldFullName, newFullName);

    expect(useGitLogPreferencesStore.getState().markedReferenceFullNamesByRepository).toEqual({
      [repoPath]: [newFullName],
    });

    actions.renameMarkedReference(repoPath, "refs/heads/missing", "refs/heads/other");
    expect(useGitLogPreferencesStore.getState().markedReferenceFullNamesByRepository).toEqual({
      [repoPath]: [newFullName],
    });

    actions.toggleMarkedReference(repoPath, newFullName);
  });
});
