import { expect, test } from "bun:test";
import { hiddenPathRules } from "./hidden-path-rules";

test("plain directory names stay names and globbed directory entries become folder globs", () => {
  expect(
    hiddenPathRules({
      hiddenDirectoryPatterns: [".git", "out/", " ", "docs/generated", "**/cache*"],
      hiddenFilePatterns: ["*.log"],
    }),
  ).toEqual({
    hiddenDirectoryNames: [".git", "out"],
    hiddenFilePatterns: ["*.log", "docs/generated/", "**/cache*/"],
  });
});
