import { expect, test } from "bun:test";

test("project tab bar exposes accessible switchable project tabs", async () => {
  const source = await Bun.file(new URL("./project-tab-bar.tsx", import.meta.url)).text();

  expect(source).toContain('role="tablist"');
  expect(source).toContain('role="tab"');
  expect(source).toContain("aria-selected");
  expect(source).toContain("isSwitchingProject");
  expect(source).toContain("switchToProject");
});
