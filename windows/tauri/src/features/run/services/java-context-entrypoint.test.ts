import { expect, test } from "bun:test";
import { withContextJavaEntrypoint } from "./java-context-entrypoint";
import type { RunConfiguration } from "../types/run.types";

test("an unmanaged file's JDT marker joins an empty workspace-wide answer", () => {
  const requested = {
    sourcePath: "Test.java",
    mainClass: "Test",
    projectName: "jdt.ls-java-project",
  };
  expect(
    withContextJavaEntrypoint({ schemaVersion: 1, entries: [], diagnostics: [] }, requested, [])
      ?.entries,
  ).toEqual([requested]);
});
test("pending discovery preserves previous entries rather than publishing a partial replacement", () => {
  const previous = [{ sourcePath: "App.java", mainClass: "App" }] as RunConfiguration[];
  expect(
    withContextJavaEntrypoint(undefined, { sourcePath: "Test.java", mainClass: "Test" }, previous)
      ?.entries,
  ).toHaveLength(2);
  expect(withContextJavaEntrypoint(undefined, undefined, previous)).toBeUndefined();
});
test("deduplicates the same Windows source but preserves equal class names in different modules", () => {
  const result = withContextJavaEntrypoint(
    {
      schemaVersion: 1,
      entries: [
        { sourcePath: "A/src/App.java", mainClass: "App" },
        { sourcePath: "B/src/App.java", mainClass: "App" },
      ],
      diagnostics: [],
    },
    { sourcePath: "a/src/App.java", mainClass: "App", projectName: "a" },
    [],
  );
  expect(result?.entries).toHaveLength(2);
  expect(result?.entries.find((entry) => entry.sourcePath.startsWith("a/"))?.projectName).toBe("a");
});
