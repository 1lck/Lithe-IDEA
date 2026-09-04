import { expect, test } from "bun:test";

test("run configuration list split wires keyboard resize and drag session cleanup", async () => {
  const source = await Bun.file(
    new URL("./run-configuration-list-split.tsx", import.meta.url),
  ).text();

  expect(source).toContain("onKeyDown={handleKeyDown}");
  expect(source).toContain("nextRunConfigurationListWidthForKey");
  expect(source).toContain("startDocumentResizeSession");
  expect(source).toContain('sessionRef.current?.dispose({ commit: true })');
  expect(source).toContain("onPointerDown={handlePointerDown}");
});
