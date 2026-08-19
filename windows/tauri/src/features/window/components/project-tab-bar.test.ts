import { expect, test } from "bun:test";

test("project tab bar exposes accessible switchable and closable project tabs", async () => {
  const source = await Bun.file(new URL("./project-tab-bar.tsx", import.meta.url)).text();

  expect(source).toContain('role="tablist"');
  expect(source).toContain('role="tab"');
  expect(source).toContain("aria-selected");
  expect(source).toContain("isSwitchingProject");
  expect(source).toContain("switchToProject");
  expect(source).toContain("closeProject");
  expect(source).toContain("XIcon as X");
  expect(source).toContain("isProjectActionPending");
  expect(source).toContain("event.stopPropagation()");
  expect(source).toContain("await closeProject(projectId)");
  expect(source).toContain("finally");
  expect(source).toContain('t("titleProject.closeProject", { name: project.name })');
  expect(source).toContain("group-hover:opacity-100");
  expect(source).toContain("group-focus-within:opacity-100");
  expect(source).toContain(
    "absolute inset-y-0 right-1 z-10 flex items-center transition-opacity",
  );
  expect(source).not.toContain("-translate-y-1/2");
});
