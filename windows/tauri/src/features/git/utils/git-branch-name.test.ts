import { expect, test } from "bun:test";
import {
  cleanBranchName,
  cleanBranchNameOnTyping,
  initialBranchName,
  validateNewBranchName,
} from "./git-branch-name";

const references = [
  { kind: "local", shortName: "main" },
  { kind: "local", shortName: "feature/login" },
  { kind: "remote", shortName: "origin/main" },
  { kind: "tag", shortName: "v1" },
] as const;

test("typing cleanup replaces spaces and drops invalid characters like IDEA", () => {
  expect(cleanBranchNameOnTyping("my new branch")).toBe("my-new-branch");
  expect(cleanBranchNameOnTyping("a~b:c^d?e*f")).toBe("abcdef");
  expect(cleanBranchNameOnTyping("a..b//c")).toBe("a.b/c");
  expect(cleanBranchNameOnTyping(".hidden")).toBe("hidden");
  expect(cleanBranchNameOnTyping("-flag")).toBe("flag");
  expect(cleanBranchNameOnTyping("a@{b")).toBe("ab");
  // A trailing slash is still allowed while the user is typing.
  expect(cleanBranchNameOnTyping("feature/")).toBe("feature/");
});

test("submit cleanup also strips trailing dot, slash and .lock", () => {
  expect(cleanBranchName("feature/")).toBe("feature");
  expect(cleanBranchName("topic.lock")).toBe("topic");
  expect(cleanBranchName("topic.")).toBe("topic");
});

test("initial name keeps local names and drops the remote prefix", () => {
  expect(initialBranchName({ kind: "local", shortName: "feature/login" })).toBe("feature/login");
  expect(initialBranchName({ kind: "remote", shortName: "origin/feature/login" })).toBe(
    "feature/login",
  );
  expect(initialBranchName({ kind: "remote", shortName: "origin" })).toBe("origin");
});

test("validation follows IDEA's order and only requires a name on apply", () => {
  expect(validateNewBranchName("", references, false)).toBeNull();
  expect(validateNewBranchName("", references, true)).toEqual({ code: "empty" });
  expect(validateNewBranchName("head", references, false)).toEqual({ code: "head" });
  expect(validateNewBranchName("origin/main", references, false)).toEqual({
    code: "clashesWithRemote",
    name: "origin/main",
  });
  expect(validateNewBranchName("feature", references, false)).toEqual({
    code: "clashesWithDirectory",
    name: "feature",
  });
  expect(validateNewBranchName("main", references, false)).toEqual({
    code: "alreadyExists",
    name: "main",
  });
  expect(validateNewBranchName("feature/signup", references, false)).toBeNull();
  // Tags do not occupy the branch namespace checked by the dialog.
  expect(validateNewBranchName("v1", references, false)).toBeNull();
});
