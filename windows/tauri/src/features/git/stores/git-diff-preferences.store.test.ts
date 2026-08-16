import { describe, expect, test } from "bun:test";
import { useGitDiffPreferencesStore } from "./git-diff-preferences.store";

describe("git diff preferences store", () => {
  test("defaults to split view like the macOS reference", () => {
    expect(useGitDiffPreferencesStore.getState().viewMode).toBe("split");
  });

  test("setViewMode switches the preference in both directions", () => {
    const { setViewMode } = useGitDiffPreferencesStore.getState().actions;

    setViewMode("unified");
    expect(useGitDiffPreferencesStore.getState().viewMode).toBe("unified");

    setViewMode("split");
    expect(useGitDiffPreferencesStore.getState().viewMode).toBe("split");
  });
});
