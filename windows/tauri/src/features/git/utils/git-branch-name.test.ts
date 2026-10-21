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

// Git keeps branches as loose refs, so `feature` and `feature/x` cannot coexist in
// either direction: both orders must be rejected before the create command runs.
test("a name whose slash prefix is an existing local branch is rejected up front", () => {
  const flatReferences = [
    { kind: "local", shortName: "main" },
    { kind: "local", shortName: "feature" },
    { kind: "remote", shortName: "origin/main" },
  ] as const;
  // Candidate name is a directory of an existing branch (feature vs feature/login).
  expect(validateNewBranchName("feature/login", flatReferences, false)).toEqual({
    code: "clashesWithBranchPrefix",
    name: "feature/login",
    branch: "feature",
  });
  // The clash may sit deeper than the first segment.
  const nestedReferences = [{ kind: "local", shortName: "a/b" }] as const;
  expect(validateNewBranchName("a/b/c", nestedReferences, false)).toEqual({
    code: "clashesWithBranchPrefix",
    name: "a/b/c",
    branch: "a/b",
  });
  // A prefix that is only a directory of other branches is not itself a clash.
  expect(validateNewBranchName("feature/signup", references, false)).toBeNull();
  // Remote branches do not occupy the local ref namespace being validated here.
  const remoteOnlyReferences = [{ kind: "remote", shortName: "origin/release" }] as const;
  expect(validateNewBranchName("release/next", remoteOnlyReferences, false)).toBeNull();
});
