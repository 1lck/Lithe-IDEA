import { expect, test } from "bun:test";
import { presentableGitErrorOutput } from "./git-checkout-failure-presentation";

test("checkout failure output drops Git severity prefixes like IDEA cleanupErrorPrefixes", () => {
  expect(
    presentableGitErrorOutput(
      "fatal: 'dev#feature' is already used by worktree at 'C:/Temp/wt_feature'\r\n",
    ),
  ).toBe("'dev#feature' is already used by worktree at 'C:/Temp/wt_feature'");
  expect(presentableGitErrorOutput("  error: pathspec 'x' did not match\n\nhint: retry")).toBe(
    "pathspec 'x' did not match\nhint: retry",
  );
});

test("checkout failure output keeps messages without a Git prefix", () => {
  expect(presentableGitErrorOutput("Local changes would be overwritten: a.txt")).toBe(
    "Local changes would be overwritten: a.txt",
  );
  expect(presentableGitErrorOutput("   ")).toBe("");
});
