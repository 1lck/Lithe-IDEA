import { describe, expect, test } from "bun:test";
import { gitGraphLabelClassName } from "./git-graph-row";

describe("git graph decoration labels", () => {
  test("uses dark text on light theme so branch pills stay readable", () => {
    expect(gitGraphLabelClassName({ title: "HEAD", kind: "head" })).toContain("text-sky-800");
    expect(gitGraphLabelClassName({ title: "master", kind: "branch" })).toContain("text-emerald-800");
    expect(gitGraphLabelClassName({ title: "origin/master", kind: "remote" })).toContain(
      "text-indigo-800",
    );
    expect(gitGraphLabelClassName({ title: "v1.0.0", kind: "tag" })).toContain("text-amber-900");
  });
});
