import { describe, expect, test } from "bun:test";
import type { RecentFolder } from "@/features/file-system/types/recent-folders.types";
import type { ProjectTab } from "@/features/window/stores/workspace-tabs.store";
import {
  getTitleProjectBadge,
  getTitleProjectMenuItemAriaCurrent,
  getTitleProjectMenuProjects,
} from "./title-project-menu-model";

const project = (id: string, path: string, isActive = false): ProjectTab => ({
  id,
  name: id,
  path,
  isActive,
  lastOpened: 1,
});

const recent = (name: string, path: string): RecentFolder => ({
  name,
  path,
  lastOpened: "2026-08-16T00:00:00.000Z",
});

describe("title project menu model", () => {
  test("keeps open projects and active state while excluding open recent paths", () => {
    const openProjects = [
      project("Lithe", "D:\\code\\Lithe", true),
      project("Online", "D:\\code\\online"),
    ];

    const result = getTitleProjectMenuProjects(openProjects, [
      recent("Lithe", "d:/code/Lithe/"),
      recent("New", "D:\\code\\new"),
    ]);

    expect(result.openProjects).toEqual(openProjects);
    expect(result.recentProjects.map((entry) => entry.name)).toEqual(["New"]);
  });

  test("caps recent projects without mutating the source list", () => {
    const recentProjects = [
      recent("A", "D:\\code\\a"),
      recent("B", "D:\\code\\b"),
      recent("C", "D:\\code\\c"),
    ];

    const result = getTitleProjectMenuProjects([], recentProjects, 2);

    expect(result.recentProjects).toEqual(recentProjects.slice(0, 2));
    expect(recentProjects).toHaveLength(3);
  });

  test("keeps existing projects open when a recent project opens in this window", () => {
    const existingProject = project("A", "D:\\code\\a", true);
    const recentProject = recent("B", "D:\\code\\b");

    const beforeOpen = getTitleProjectMenuProjects([existingProject], [recentProject]);
    expect(beforeOpen.recentProjects.map((entry) => entry.name)).toEqual(["B"]);

    const openedProject = project("B", "D:\\code\\b", true);
    const afterOpen = getTitleProjectMenuProjects(
      [{ ...existingProject, isActive: false }, openedProject],
      [recentProject],
    );

    expect(afterOpen.openProjects.map((entry) => entry.name)).toEqual(["A", "B"]);
    expect(afterOpen.recentProjects).toEqual([]);
  });

  test("marks only the active project as current for assistive technology", () => {
    expect(getTitleProjectMenuItemAriaCurrent(true)).toBe("true");
    expect(getTitleProjectMenuItemAriaCurrent(false)).toBeUndefined();
  });

  test("creates deterministic project initials and badge tones", () => {
    const badge = getTitleProjectBadge("Lithe-IDEA-issue-35-ci");

    expect(badge.initials).toBe("LI");
    expect(getTitleProjectBadge("Lithe-IDEA-issue-35-ci")).toEqual(badge);
    expect(getTitleProjectBadge("文档项目").initials).toBe("文");
  });
});
