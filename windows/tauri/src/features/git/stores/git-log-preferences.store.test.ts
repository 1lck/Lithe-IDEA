import { describe, expect, test } from "bun:test";
import { useGitLogPreferencesStore } from "./git-log-preferences.store";

describe("Git Log preferences", () => {
  test("persists read-only view preferences through focused actions", () => {
    const actions = useGitLogPreferencesStore.getState().actions;

    actions.setFilterQuery("graph");
    actions.setFilterScope("author");
    actions.setShowDecorations(false);
    actions.setMainPanelLayout({ references: 20, commits: 55, inspector: 25 });
    actions.setInspectorPanelLayout({ files: 70, details: 30 });
    actions.toggleReferenceSection("remote");
    actions.toggleReferenceGroup("remote:origin");

    expect(useGitLogPreferencesStore.getState()).toMatchObject({
      filterQuery: "graph",
      filterScope: "author",
      showDecorations: false,
      mainPanelLayout: { references: 20, commits: 55, inspector: 25 },
      inspectorPanelLayout: { files: 70, details: 30 },
      collapsedReferenceSections: ["remote"],
      collapsedReferenceGroups: ["remote:origin"],
    });

    actions.setFilterQuery("");
    actions.setFilterScope("text");
    actions.setShowDecorations(true);
    actions.setMainPanelLayout({ references: 19, commits: 57, inspector: 24 });
    actions.setInspectorPanelLayout({ files: 62, details: 38 });
    actions.toggleReferenceSection("remote");
    actions.toggleReferenceGroup("remote:origin");
  });
});
